//
//  TextTileManager.swift
//  CodeEditTextView
//

import AppKit

/// Renders a view's content into fixed-size tiles: plain `CALayer`s, each with its own backing store. The view is a
/// ``TextView``, or a view drawn alongside one that follows its layout (see ``TextTileFollower``).
///
/// ## Why tiles
///
/// A document-sized layer-backed view keeps one backing store for its visible region, and Core Animation copies that
/// whole store before every partial redraw. A keystroke dirties one line but paid for a copy of the entire viewport -
/// the largest single cost of typing, with frame spikes past 10 ms. A tile's store is a small fraction of that, so a
/// redraw copies only the tiles it touches. Tiles also keep their pixels while they scroll: scrolling draws a tile
/// once, when it comes into range, instead of a strip of the viewport on every frame.
///
/// ## Why plain layers
///
/// On every scroll step AppKit invalidates the newly exposed strip of the document view in every view beneath it,
/// directly on their layers and without going through `setNeedsDisplay(_:)`. Tiles made of views would each redraw,
/// and copy their store, on every scroll tick. Plain sublayers sit outside that machinery and redraw only when told.
///
/// ## Invariant
///
/// Once pending displays have run, every tile shows exactly what the view draws for its rect:
///   * a new tile is entirely dirty;
///   * the view forwards every invalidation to the tiles it touches (``TextView/setNeedsDisplay(_:)``);
///   * each layout pass dirties the band where its fragments differ from the previous pass's, across every tile that
///     existed before it (see ``TextLayoutManager``'s redraw decision), in the text view and in every follower;
///   * everything else a draw reads - appearance, backing scale, selection and decoration state - is invalidated by
///     its owner when it changes.
///
/// A tile's pixels outlive the viewport that was current when they were drawn, so drawing must depend only on
/// document position: never on the viewport, nor on which rect happens to be drawn.
final class TextTileManager: NSObject, CALayerDelegate {
    /// A tile's position in the grid, in tile units from the document origin.
    struct Key: Hashable {
        let row: Int
        let column: Int
    }

    /// Tile size in points. Wide enough that wrapped text is a single column at common widths, short enough that a
    /// one-line change copies a small store. 128 and 256 pt rows measured within noise of each other; 256 needs half
    /// as many layers.
    static let tileSize = CGSize(width: 1024, height: 256)

    /// The viewport grows by this much on each end before tiles are created for it, so a sub-point scroll the view
    /// skips a layout pass for can never expose a point no tile covers.
    static let creationMargin: CGFloat = 32

    /// Tiles up to this far beyond the region that requires them survive, so a tile that scrolls just out of range is
    /// still there when it scrolls back. They must also lie inside a layout band, where their fragments are tracked:
    /// with the default 350 pt layout padding, a tile reaching 90 pt past the viewport ends 346 pt past it.
    static let retentionMargin: CGFloat = 90

    /// How far beyond the viewport a band AppKit asks to have prepared (responsive scrolling) is covered with tiles.
    static let maximumOverdraw: CGFloat = 512

    /// The pixel format of every tile's store.
    ///
    /// Left alone, Core Animation picks a format for each update from what that update drew: one byte of alpha for
    /// text in a single color, gray and alpha for gray fills, half floats once an emoji is drawn. A tile then
    /// switches format between partial redraws, and the pixels it keeps are converted each time: emoji colors and
    /// gray fills shift by a few levels when an unrelated line in the same tile is redrawn. Pinning one format keeps
    /// a tile's pixels exactly as they were drawn.
    static let contentsFormat: CALayerContentsFormat = .RGBA8Uint

    /// Parent of every tile, kept below every other sublayer of the view (a text view's cursors, view zones and
    /// emphases).
    let containerLayer: CALayer

    /// The live tiles, in no particular order. A few dozen at most, so linear scans beat any keyed structure.
    private(set) var tiles: ContiguousArray<TextTileLayer> = []

    /// The view whose content the tiles show, and whose layer holds them.
    private weak var view: NSView?

    /// Draws the view's content for a rect, in the view's coordinates, into the current graphics context.
    private let drawContents: (NSRect) -> Void

    private var contentsScale: CGFloat = 1

    /// Whether the view asks to render through tiles. They are only used while it is also layer-backed.
    var isEnabled = true

    init(view: NSView, draw: @escaping (NSRect) -> Void) {
        self.view = view
        drawContents = draw
        containerLayer = CALayer()
        super.init()
        containerLayer.name = "TextTiles"
        containerLayer.delegate = self
        containerLayer.anchorPoint = .zero
        containerLayer.frame = .zero
        containerLayer.zPosition = -1
    }

    /// Whether the view currently renders through tiles: it asks to, and it is layer-backed.
    var isActive: Bool {
        isEnabled && view?.layer != nil
    }

    /// Whether any tile has a display pending.
    var needsDisplay: Bool {
        tiles.contains { $0.needsDisplay() }
    }

    /// Puts the tile container into `hostLayer`, beneath everything else in it.
    func attach(to hostLayer: CALayer) {
        guard containerLayer.superlayer !== hostLayer else { return }
        containerLayer.removeFromSuperlayer()
        hostLayer.insertSublayer(containerLayer, at: 0)
    }

    /// Drops every tile and takes the container out of the layer tree.
    func detach() {
        removeAllTiles()
        containerLayer.removeFromSuperlayer()
    }

    /// Drops every tile. The next coverage update recreates the ones it needs, entirely dirty.
    func removeAllTiles() {
        for tile in tiles {
            tile.removeFromSuperlayer()
        }
        tiles.removeAll()
    }

    // MARK: - Invalidation

    /// Dirties `rect`, in the view's coordinates, in every tile it touches.
    ///
    /// The dirty rect is grown to whole device pixels. Core Animation clears every pixel a dirty rect touches but
    /// clips the redraw to the rect itself, so a pixel row the rect only partly covers would be cleared and then
    /// only partly redrawn - antialiased glyph edges along it would come back fainter or heavier than before.
    func setNeedsDisplay(_ rect: NSRect) {
        guard !rect.isEmpty else { return }
        let scale = contentsScale
        for tile in tiles {
            let frame = tile.frame
            guard frame.intersects(rect) else { continue }
            let local = rect.intersection(frame).offsetBy(dx: -frame.minX, dy: -frame.minY)
            let minX = (local.minX * scale).rounded(.down) / scale
            let minY = (local.minY * scale).rounded(.down) / scale
            let maxX = (local.maxX * scale).rounded(.up) / scale
            let maxY = (local.maxY * scale).rounded(.up) / scale
            tile.setNeedsDisplay(NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
        }
    }

    /// Dirties every tile entirely.
    func setNeedsDisplayAll() {
        for tile in tiles {
            tile.setNeedsDisplay()
        }
    }

    /// Draws every tile with a display pending, now.
    func displayIfNeeded() {
        for tile in tiles {
            tile.displayIfNeeded()
        }
    }

    /// Adopts the backing scale tiles must render at, redrawing every tile when it changed.
    func setContentsScale(_ scale: CGFloat) {
        guard scale > 0, scale != contentsScale else { return }
        contentsScale = scale
        for tile in tiles {
            tile.contentsScale = scale
            tile.setNeedsDisplay()
        }
    }

    // MARK: - Coverage

    /// Brings the set of tiles in line with a layout pass of the text view the view shows or follows.
    ///
    /// Creates a tile for every grid cell the pass's region needs and drops the tiles that are no longer worth
    /// keeping. A tile is kept while it touches the required region, or while it lies within ``retentionMargin`` of
    /// it *and* entirely inside one of the pass's layout bands: there every fragment it can show is laid out on every
    /// pass, so the fragment diff tracks all of its pixels and the churn at the band edges never reaches it.
    ///
    /// - Parameters:
    ///   - viewport: The part of the view on screen, in its coordinates. Empty when it has no host, which leaves
    ///     nothing to cover.
    ///   - pass: The rect the pass laid out. It covers `viewport`, and any band AppKit asked to have prepared.
    ///   - bands: The y-bands the pass's fragments cover, when known.
    /// - Returns: The bounding rect of the tiles that existed before this call and are kept unchanged. Their pixels
    ///   showed the previous pass's fragments, so this is the region the pass's fragment diff has to repaint. `nil`
    ///   when no tile was kept; every other tile is entirely dirty already.
    func updateCoverage(
        viewport: NSRect,
        pass: NSRect,
        bands: TextLayoutManager.LayoutPassBands?
    ) -> NSRect? {
        guard let view, let hostLayer = view.layer else { return nil }
        attach(to: hostLayer)
        let bounds = view.bounds
        guard !viewport.isEmpty, bounds.width > 0 else {
            removeAllTiles()
            return nil
        }

        let required = requiredRegion(viewport: viewport, pass: pass, bounds: bounds)
        let retained = required.insetBy(dx: -Self.tileSize.width, dy: -Self.retentionMargin)
        var kept: NSRect?
        var index = 0
        while index < tiles.count {
            let tile = tiles[index]
            let frame = Self.frame(for: tile.key, boundsWidth: bounds.width)
            let keep = frame.width > 0
                && (frame.intersects(required) || (frame.intersects(retained) && Self.contains(bands, frame)))
            guard keep else {
                tile.removeFromSuperlayer()
                tiles.swapAt(index, tiles.count - 1)
                tiles.removeLast()
                continue
            }
            if tile.frame != frame {
                // The view's width changed under an edge column. Its old pixels no longer fit; redraw it whole.
                tile.frame = frame
                tile.setNeedsDisplay()
            } else {
                kept = kept.map { $0.union(frame) } ?? frame
            }
            index += 1
        }

        addMissingTiles(in: required, boundsWidth: bounds.width)
        return kept
    }

    /// The region that must be covered with tiles: the viewport, plus whatever part of the pass's rect lies within
    /// ``maximumOverdraw`` of it, grown by ``creationMargin`` and clamped to the document's left, right and top edges.
    private func requiredRegion(viewport: NSRect, pass: NSRect, bounds: NSRect) -> NSRect {
        var region = viewport
        let prepared = pass.intersection(viewport.insetBy(dx: -Self.maximumOverdraw, dy: -Self.maximumOverdraw))
        if !prepared.isEmpty {
            region = region.union(prepared)
        }
        region = region.insetBy(dx: 0, dy: -Self.creationMargin)
        let minX = max(region.minX, bounds.minX)
        let maxX = min(region.maxX, bounds.maxX)
        let minY = max(region.minY, 0)
        return NSRect(x: minX, y: minY, width: max(maxX - minX, 0), height: max(region.maxY - minY, 0))
    }

    private func addMissingTiles(in region: NSRect, boundsWidth: CGFloat) {
        guard !region.isEmpty else { return }
        let size = Self.tileSize
        let firstRow = Int((region.minY / size.height).rounded(.down))
        let lastRow = Int((region.maxY / size.height).rounded(.up)) - 1
        let firstColumn = Int((region.minX / size.width).rounded(.down))
        let lastColumn = Int((region.maxX / size.width).rounded(.up)) - 1
        guard firstRow <= lastRow, firstColumn <= lastColumn else { return }
        for row in firstRow...lastRow {
            for column in firstColumn...lastColumn {
                let key = Key(row: row, column: column)
                guard !tiles.contains(where: { $0.key == key }) else { continue }
                let frame = Self.frame(for: key, boundsWidth: boundsWidth)
                guard frame.width > 0 else { continue }
                let tile = TextTileLayer(key: key)
                tile.delegate = self
                tile.anchorPoint = .zero
                tile.frame = frame
                tile.contentsScale = contentsScale
                tile.contentsFormat = Self.contentsFormat
                containerLayer.addSublayer(tile)
                tile.setNeedsDisplay()
                tiles.append(tile)
            }
        }
    }

    /// Whether tiles cover every point of `rect`.
    func covers(_ rect: NSRect) -> Bool {
        guard !rect.isEmpty else { return true }
        let size = Self.tileSize
        let firstRow = Int((max(rect.minY, 0) / size.height).rounded(.down))
        let lastRow = Int((rect.maxY / size.height).rounded(.up)) - 1
        let firstColumn = Int((max(rect.minX, 0) / size.width).rounded(.down))
        let lastColumn = Int((rect.maxX / size.width).rounded(.up)) - 1
        guard firstRow <= lastRow, firstColumn <= lastColumn else { return true }
        for row in firstRow...lastRow {
            for column in firstColumn...lastColumn {
                let key = Key(row: row, column: column)
                guard tiles.contains(where: { $0.key == key }) else { return false }
            }
        }
        return true
    }

    /// The frame of the tile at `key`. The last column is cut at the view's right edge, rounded up to a whole
    /// point: a store whose width is not a whole number of pixels is resampled into its layer, which softens every
    /// glyph edge in the column.
    static func frame(for key: Key, boundsWidth: CGFloat) -> NSRect {
        let minX = CGFloat(key.column) * tileSize.width
        return NSRect(
            x: minX,
            y: CGFloat(key.row) * tileSize.height,
            width: max(min(tileSize.width, (boundsWidth - minX).rounded(.up)), 0),
            height: tileSize.height
        )
    }

    /// Whether `frame`'s y-extent lies entirely inside one of `bands`.
    private static func contains(_ bands: TextLayoutManager.LayoutPassBands?, _ frame: NSRect) -> Bool {
        guard let bands else { return false }
        if bands.first.minY <= frame.minY && frame.maxY <= bands.first.maxY {
            return true
        }
        guard let second = bands.second else { return false }
        return second.minY <= frame.minY && frame.maxY <= second.maxY
    }

    // MARK: - CALayerDelegate

    /// Draws a tile by running the view's own drawing for the tile's dirty rect, in the view's coordinates.
    ///
    /// The context is set up as AppKit sets it up for a flipped view's `draw(_:)` - current graphics context, current
    /// drawing appearance - so the tile's pixels are identical to the ones the view would draw itself.
    func draw(_ layer: CALayer, in ctx: CGContext) {
        guard let view, let tile = layer as? TextTileLayer else { return }
        let dirty = ctx.boundingBoxOfClipPath.intersection(tile.bounds)
        guard !dirty.isEmpty else { return }
        let origin = tile.frame.origin
        ctx.saveGState()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        ctx.translateBy(x: -origin.x, y: -origin.y)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            drawContents(dirty.offsetBy(dx: origin.x, dy: origin.y))
        }
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    /// No implicit animations: a tile that moves, resizes or gets new pixels must change in the same frame.
    func action(for layer: CALayer, forKey event: String) -> CAAction? {
        NSNull()
    }
}

/// A tile: a plain layer that knows its grid position.
final class TextTileLayer: CALayer {
    let key: TextTileManager.Key

    init(key: TextTileManager.Key) {
        self.key = key
        super.init()
        name = "TextTile"
    }

    /// Used by Core Animation to make presentation copies.
    override init(layer: Any) {
        key = (layer as? TextTileLayer)?.key ?? TextTileManager.Key(row: 0, column: 0)
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
