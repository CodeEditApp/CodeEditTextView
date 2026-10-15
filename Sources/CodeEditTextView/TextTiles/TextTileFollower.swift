//
//  TextTileFollower.swift
//  CodeEditTextView
//

import AppKit

/// Renders a view drawn alongside a ``TextView`` - a gutter, say - through tiles that follow the text view's layout.
///
/// A document-sized view beside the text pays what the text view paid before it had tiles: AppKit keeps one backing
/// store for its visible region and redraws a strip of it on every scroll step. Its tiles, like the text view's, keep
/// their pixels while they scroll, so scrolling draws each of them once, when it comes into range.
///
/// ## What the view must do
///
/// The view draws in the text view's vertical coordinates: what it draws at y belongs to whatever sits at y in the
/// text view. Its tiles cover the rows around its visible rect, and every layout pass of the text view repaints, in
/// them, the band where the pass's fragments changed, as it does in the text view's own tiles. Everything else its
/// drawing reads is the view's to invalidate, and it forwards every invalidation:
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
/// plus ``refreshCoverage()`` when its frame changes or it is shown again, ``updateForWindow()`` when it moves to
/// another window or that window's backing properties change, and ``setNeedsDisplayAll()`` when its appearance
/// changes. A tile's pixels outlive the visible rect that was current when they were drawn, so the drawing must
/// depend only on position: never on what is visible, nor on which rect happens to be drawn.
///
/// While the text view does not render through tiles, neither does the follower (``isActive`` is `false`): the view
/// keeps its own backing store and draws as usual.
public final class TextTileFollower {
    private weak var textView: TextView?
    private weak var view: NSView?
    let tiles: TextTileManager

    /// Creates the tiles for `view`, which follows `textView`'s layout.
    /// - Parameters:
    ///   - view: The view to render through tiles. It must draw in `textView`'s vertical coordinates.
    ///   - textView: The text view whose layout `view` follows.
    ///   - draw: Draws `view`'s content for a rect, in its coordinates, into the current graphics context. It is set
    ///     up as for the view's own `draw(_:)`: flipped, with the view's appearance current. Capture `view` weakly;
    ///     the follower is usually owned by it.
    public init(view: NSView, textView: TextView, draw: @escaping (NSRect) -> Void) {
        self.textView = textView
        self.view = view
        tiles = TextTileManager(view: view, draw: draw)
        textView.layoutManager.addTileFollower(self)
        if let layer = view.layer {
            tiles.attach(to: layer)
        }
    }

    deinit {
        tiles.detach()
    }

    /// How far the view's drawing for a line can reach past the line's band, above or below it. Every band the text
    /// view's layout repaints is grown by this much in the view's tiles.
    public var bandOutset: CGFloat = 0

    /// Whether the view renders through tiles: the text view does, and the view is layer-backed.
    public var isActive: Bool {
        guard tiles.isActive, let textView else { return false }
        return textView.layoutManager?.activeTileManager != nil
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
        if let view, !view.isHiddenOrHasHiddenAncestor, !tiles.covers(view.visibleRect.intersection(view.bounds)) {
            refreshCoverage()
        }
        tiles.displayIfNeeded()
    }

    /// Brings the tiles in line with the view's geometry outside a layout pass: after its frame changed, or after it
    /// was shown again.
    public func refreshCoverage() {
        guard isActive, let layoutManager = textView?.layoutManager else { return }
        let viewport = layoutManager.viewportRect()
        _ = updateCoverage(viewport: viewport, pass: viewport, bands: layoutManager.lastPassBands)
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

    /// Brings the tiles in line with a layout pass of the text view.
    ///
    /// The rows to cover come from the text view's viewport, mapped into the view by the drawing contract (same
    /// vertical coordinates), as well as from the view's own visible rect. A pass can run in the middle of a scroll,
    /// from `prepareContent(in:)`, before AppKit has moved views outside the clip view (a scroll view's floating
    /// subviews) to their new place, so the view's own visible rect may still be the one from before the scroll.
    /// - Parameters:
    ///   - viewport: The text view's on-screen region, in its coordinates. Empty when it has none.
    ///   - pass: The rect the pass laid out, in the text view's coordinates. Only its vertical extent applies.
    ///   - bands: The y-bands the pass's fragments cover, when known.
    /// - Returns: The bounding rect of the tiles kept unchanged; see
    ///   ``TextTileManager/updateCoverage(viewport:pass:bands:)``.
    func updateCoverage(viewport: NSRect, pass: NSRect, bands: TextLayoutManager.LayoutPassBands?) -> NSRect? {
        guard let view else { return nil }
        guard !view.isHiddenOrHasHiddenAncestor, !viewport.isEmpty else {
            return tiles.updateCoverage(viewport: .zero, pass: .zero, bands: bands)
        }
        let width = view.bounds.width
        var visible = NSRect(x: 0, y: viewport.minY, width: width, height: viewport.height)
        let ownVisible = view.visibleRect.intersection(view.bounds)
        if !ownVisible.isEmpty {
            visible = visible.union(ownVisible)
        }
        let followerPass = NSRect(x: 0, y: pass.minY, width: width, height: pass.height)
        return tiles.updateCoverage(viewport: visible, pass: followerPass, bands: bands)
    }

    /// The text view started or stopped rendering through tiles.
    func tilingDidChange() {
        guard let view else { return }
        if !isActive {
            tiles.detach()
        }
        view.needsDisplay = true
    }
}

extension TextLayoutManager {
    /// A follower the layout manager keeps without owning it: the follower belongs to its view.
    struct WeakTileFollower {
        weak var follower: TextTileFollower?
    }

    func addTileFollower(_ follower: TextTileFollower) {
        tileFollowers.removeAll { $0.follower == nil }
        tileFollowers.append(WeakTileFollower(follower: follower))
    }

    /// Brings every follower's tiles in line with a completed pass, and repaints in them the band where the pass's
    /// fragments changed. A forced pass re-typeset everything, so every follower tile is repainted.
    func updateTileFollowers(forceLayout: Bool, viewport: NSRect, pass: NSRect, bands: LayoutPassBands) {
        for entry in tileFollowers {
            guard let follower = entry.follower, follower.isActive else { continue }
            let kept = follower.updateCoverage(viewport: viewport, pass: pass, bands: bands)
            let outset = follower.bandOutset
            if forceLayout {
                follower.tiles.setNeedsDisplayAll()
            } else if let kept, let band = changedFragmentBand(in: kept.insetBy(dx: 0, dy: -outset)) {
                follower.tiles.setNeedsDisplay(NSRect(
                    x: kept.minX,
                    y: band.minY - outset,
                    width: kept.width,
                    height: band.maxY - band.minY + 2 * outset
                ))
            }
        }
    }

    /// Covers each follower's visible rect from the last completed pass's fragments, for a pass that was skipped.
    func updateTileFollowerCoverage(viewport: NSRect, pass: NSRect) {
        for entry in tileFollowers {
            guard let follower = entry.follower, follower.isActive else { continue }
            _ = follower.updateCoverage(viewport: viewport, pass: pass, bands: lastPassBands)
        }
    }

    /// The layout view started or stopped rendering through tiles.
    func tilingDidChange() {
        for entry in tileFollowers {
            entry.follower?.tilingDidChange()
        }
    }
}
