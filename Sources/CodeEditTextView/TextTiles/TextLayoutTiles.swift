//
//  TextLayoutTiles.swift
//  CodeEditTextView
//

import AppKit

/// Renders the view a ``TextLayoutManager`` lays out into through tiles, when that view is not a ``TextView``: a
/// minimap's content view, say.
///
/// The tiles work as a text view's do (see ``TextTileManager``): they keep their pixels while they scroll, so
/// scrolling draws a tile once, when it comes into range, and every layout pass repaints only the band where its
/// fragments changed. Without them, such a view keeps one backing store for its visible region, which AppKit redraws
/// on every scroll step.
///
/// ## What the view must do
///
/// ```swift
/// override var wantsUpdateLayer: Bool { tiles.isActive }
/// override func updateLayer() { tiles.displayIfNeeded() }
/// override func setNeedsDisplay(_ rect: NSRect) {
///     super.setNeedsDisplay(rect)
///     tiles.setNeedsDisplay(rect)
/// }
/// ```
///
/// plus ``refreshCoverage()`` after its width changes, ``updateForWindow()`` when it moves to another window or that
/// window's backing properties change, and ``setNeedsDisplayAll()`` when its appearance changes. A tile's pixels
/// outlive the visible rect that was current when they were drawn, so the drawing must depend only on position.
public final class TextLayoutTiles {
    let tiles: TextTileManager
    private weak var view: NSView?
    private weak var layoutManager: TextLayoutManager?
    private weak var selectionManager: TextSelectionManager?

    /// Creates the tiles for `view` and has `layoutManager` render it through them.
    /// - Parameters:
    ///   - layoutManager: The layout manager whose layout view `view` is.
    ///   - view: The view to render through tiles.
    ///   - selectionManager: A selection manager that draws into `view`, if any. It is told after every layout pass,
    ///     as a text view's is, so its record of where selections were painted follows lines that moved.
    ///   - draw: Draws `view`'s content for a rect, in its coordinates, into the current graphics context. It is set
    ///     up as for the view's own `draw(_:)`: flipped, with the view's appearance current. Capture `view` weakly;
    ///     the tiles are usually owned by it.
    public init(
        layoutManager: TextLayoutManager,
        view: NSView,
        selectionManager: TextSelectionManager? = nil,
        draw: @escaping (NSRect) -> Void
    ) {
        tiles = TextTileManager(view: view, draw: draw)
        self.view = view
        self.layoutManager = layoutManager
        self.selectionManager = selectionManager
        layoutManager.tileManager = tiles
        layoutManager.layoutTiles = self
        if let layer = view.layer {
            tiles.attach(to: layer)
        }
        layoutManager.setNeedsLayout()
    }

    deinit {
        tiles.detach()
    }

    /// Whether the view renders through tiles: it is layer-backed.
    public var isActive: Bool {
        tiles.isActive
    }

    /// Dirties `rect`, in the view's coordinates, in every tile it touches.
    public func setNeedsDisplay(_ rect: NSRect) {
        guard isActive else { return }
        tiles.setNeedsDisplay(rect)
    }

    /// Dirties every tile entirely.
    public func setNeedsDisplayAll() {
        tiles.setNeedsDisplayAll()
    }

    /// Draws every dirty tile, after covering whatever part of the view's visible rect has no tile yet. Layout
    /// passes keep the tiles in step with scrolling; this only catches what reaches the screen between them.
    public func displayIfNeeded() {
        guard isActive else { return }
        // A view that doesn't clip to its bounds reports a visible rect reaching past them, where it shows nothing.
        if let view, !tiles.covers(view.visibleRect.intersection(view.bounds)) {
            refreshCoverage()
        }
        tiles.displayIfNeeded()
    }

    /// Brings the tiles in line with the view's geometry outside a layout pass, after its width changed. The
    /// fragments are those of the last pass.
    public func refreshCoverage() {
        layoutManager?.refreshTileCoverage()
    }

    /// Adopts the window's backing scale and redraws every tile: pixels drawn for another window, or before there was
    /// one, differ from what this window would draw. Without a window the tiles are dropped until it comes back.
    public func updateForWindow() {
        guard let window = view?.window else {
            tiles.removeAllTiles()
            return
        }
        tiles.setContentsScale(window.backingScaleFactor)
        tiles.setNeedsDisplayAll()
    }

    /// Runs after every layout pass of the layout manager.
    func layoutPassDidComplete() {
        selectionManager?.layoutPassDidComplete()
    }
}
