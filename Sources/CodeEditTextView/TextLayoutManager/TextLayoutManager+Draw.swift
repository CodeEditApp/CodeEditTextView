//
//  TextLayoutManager+Draw.swift
//  CodeEditTextView
//
//  Created by Abe Malla on 4/19/26.
//

import AppKit

extension TextLayoutManager {
    /// Draws every visible fragment intersecting `dirtyRect` into the current graphics context.
    ///
    /// This is the drawing side of the single-layer architecture: layout populates `visibleFragments`, then the text
    /// view's `draw(_:)` calls this to rasterize them. Takes no locks - we only read `visibleFragments` which is only
    /// mutated under `layoutLock` during a layout pass, and AppKit guarantees `draw(_:)` does not overlap a layout pass
    /// on the same view.
    ///
    /// A fragment is drawn when its pixels reach into the rect - its rect grown by the ink that paints past it - so a
    /// partial redraw puts back whatever a neighboring line's glyphs had painted there.
    ///
    /// Fragment rects are y-ordered and don't overlap, so the walk starts at the first fragment whose rect reaches
    /// below the rect's top less the deepest ink overhang (a binary search), and stops past the rect's bottom plus
    /// the tallest. A tile draws a few lines out of a list several hundred long, and several tiles may draw in one
    /// frame.
    public func drawVisibleFragments(in dirtyRect: NSRect) {
        guard let graphicsContext = NSGraphicsContext.current else { return }
        let context = graphicsContext.cgContext
        // These pixels are now backed by the current fragment list; the layout pass consults this record to
        // decide whether newly revealed viewport strips still need a draw. Only screen draws count - printing,
        // PDF export, and `cacheDisplay` snapshots also route through here, and crediting those would claim
        // regions the window backing store never received (blanking them on the next reveal). Tiles keep no
        // such record: their pixels outlive the viewport.
        if activeTileManager == nil && graphicsContext.isDrawingToScreen {
            recordRasterizedDraw(dirtyRect)
        }
        let renderer = lineFragmentRenderer
        renderer.beginDrawPass()
        defer { renderer.endDrawPass() }

        let overflow = visibleInkOverflow
        visibleFragments.withUnsafeBufferPointer { fragments in
            var index = Self.firstFragment(in: fragments, reachingBelow: dirtyRect.minY - overflow.below)
            while index < fragments.count {
                let visible = fragments[index]
                guard visible.yPos < dirtyRect.maxY + overflow.above else { break }
                index += 1
                guard visible.drawMinY < dirtyRect.maxY, visible.drawMaxY > dirtyRect.minY else { continue }
                context.saveGState()
                context.translateBy(x: visible.xPos, y: visible.yPos)
                renderer.draw(lineFragment: visible.fragment, in: context, yPos: 0.0)
                context.restoreGState()
            }
        }
    }

    /// The index of the first fragment whose bottom lies below `minY`, or `fragments.count` when there is none.
    private static func firstFragment(
        in fragments: UnsafeBufferPointer<VisibleFragment>,
        reachingBelow minY: CGFloat
    ) -> Int {
        var low = 0
        var high = fragments.count
        while low < high {
            let middle = (low + high) / 2
            if fragments[middle].yPos + fragments[middle].height > minY {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low
    }

    /// Credits the pixels a draw actually committed, rect by rect.
    ///
    /// A single `draw(_:)` can satisfy several disjoint `setNeedsDisplay(_:)` rects - `applyRedrawDecision`
    /// issues up to five per pass. AppKit then clips the context to those rects individually while passing only
    /// their bounding box as `dirtyRect`, so the fragments in the gaps between them are drawn into a clipped-out
    /// context and leave no pixels. Crediting the bounding box would claim those gaps as committed and the next
    /// reveal would skip them - a blank. Each rect is credited separately instead; a disjoint commit replaces
    /// the claim rather than unioning across a gap, which costs at most a redundant redraw.
    private func recordRasterizedDraw(_ dirtyRect: NSRect) {
        guard let layoutView else {
            recordRasterized(dirtyRect)
            return
        }
        var rects: UnsafePointer<NSRect>?
        var count: Int = 0
        layoutView.getRectsBeingDrawn(&rects, count: &count)
        // Outside a real draw AppKit reports nothing; the bounding rect is then all the information there is.
        guard let rects, count > 0 else {
            recordRasterized(dirtyRect)
            return
        }
        for index in 0..<count {
            recordRasterized(rects[index].intersection(dirtyRect))
        }
    }
}
