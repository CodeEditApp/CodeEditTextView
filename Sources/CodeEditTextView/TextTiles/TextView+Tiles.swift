//
//  TextView+Tiles.swift
//  CodeEditTextView
//

import AppKit

/// The text view's side of tiled rendering (see ``TextTileManager``): its own layer stays empty, and every
/// invalidation and every change to how pixels look is passed on to the tiles.
extension TextView {
    /// With tiles, the view's own layer holds no content: AppKit allocates no backing store for it and never calls
    /// `draw(_:)` to fill one. Without a layer this has no effect, and the view draws itself.
    override public var wantsUpdateLayer: Bool {
        usesTiledRendering
    }

    /// Runs when the view's own layer is displayed, after an invalidation of the view - ours or AppKit's. Draws the
    /// tiles that are dirty now, so a synchronous display of the view (`display()`, `displayIfNeeded()`) also brings
    /// its tiles up to date.
    override public func updateLayer() {
        tileManager.displayIfNeeded()
    }

    /// A width change resizes the last column of tiles, and can add or drop columns. The layout pass that usually
    /// follows does this too, but a frame change can come after the pass that caused it (a wider line found during
    /// the pass), and the tiles must fit the view before the next display.
    override public func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged {
            layoutManager?.refreshTileCoverage()
        }
    }

    /// Every pixel the view currently holds: the viewport, and with tiles every tile, wherever it is.
    var drawnRegion: NSRect {
        layoutManager?.drawnRegion ?? visibleRect.intersection(bounds)
    }

    /// Runs after every layout pass the layout manager completes.
    func layoutPassDidComplete() {
        // Emphasis layers sit above the tiles and follow the layout. Scrolling over tiles that are already drawn runs
        // no draw, so they are brought up to date here rather than only from `draw(_:)`.
        emphasisManager?.updateLayerBackgrounds()
        selectionManager?.layoutPassDidComplete()
    }

    /// Dirties `invalidRect` in the view and in every tile it touches.
    override public func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(invalidRect)
        guard let tiles = layoutManager?.activeTileManager else { return }
        tiles.setNeedsDisplay(invalidRect)
    }

    /// Dynamic colors resolve differently under the new appearance, in every tile, on screen or not.
    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layoutManager?.activeTileManager?.setNeedsDisplayAll()
    }

    /// The backing scale or color space changed (the window moved to another display, or the display changed).
    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateTilesForWindow()
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            // Off screen until it comes back; a pass in the new window recreates what it needs.
            tileManager.removeAllTiles()
            return
        }
        updateTilesForWindow()
    }

    /// Tiles render at the window's backing scale, and their stores take the window's color space. Pixels drawn for
    /// another window, or before there was one, differ from what this window would draw, so every tile is redrawn.
    private func updateTilesForWindow() {
        guard let window else { return }
        tileManager.setContentsScale(window.backingScaleFactor)
        tileManager.setNeedsDisplayAll()
    }
}
