//
//  TextLayoutManager+Invalidation.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 2/24/24.
//

import AppKit

extension TextLayoutManager {
    /// The rect a layout pass over `rect` must actually cover, together with the live viewport used for the
    /// pass's redraw decision.
    ///
    /// Every pass replaces `visibleFragments` wholesale and `draw(_:)` renders only from that list, so a pass
    /// that doesn't cover the viewport leaves the rest of the screen with nothing to draw from. What the
    /// returned pass guarantees: it covers every point of a known viewport, and nothing beyond it that was not
    /// asked for.
    ///
    ///   * `NSRect.union` of two *disjoint* rects spans everything between them. A request further from the
    ///     viewport than one ``verticalLayoutPadding`` - the band every pass adds around itself anyway, and so
    ///     the widest gap a union can close for free - yields the viewport alone instead. That request is then
    ///     not laid out at all: one rect cannot hold both bands without the gap between them, and on-screen
    ///     coverage is not negotiable.
    ///   * an unbounded request (see ``isUnbounded(_:)``) says nothing about what to lay out, so it too yields
    ///     the viewport alone rather than the whole document.
    ///
    /// With no viewport (see ``viewportRect()``) there is nothing to cover and the request stands alone.
    func layoutPassRects(for rect: NSRect) -> (pass: NSRect, viewport: NSRect) {
        let viewport = viewportRect()
        guard !viewport.isEmpty else {
            return (Self.isUnbounded(rect) ? .zero : rect, viewport)
        }
        guard !Self.isUnbounded(rect) else { return (viewport, viewport) }
        // Positive only when the two are disjoint: the distance a union would have to fabricate coverage over.
        let gap = max(rect.minY - viewport.maxY, viewport.minY - rect.maxY)
        guard gap <= verticalLayoutPadding else { return (viewport, viewport) }
        return (rect.union(viewport), viewport)
    }

    /// Whether `rect` carries no usable bound on what to lay out.
    ///
    /// `CGRect.infinite` is what AppKit reports as the visible rect of a view nothing clips - a view with no
    /// superview - and it reaches a pass through the delegate's preferred layout rect. It means "no clipping
    /// information", never "lay out the document". Its height is `greatestFiniteMagnitude`, so rects derived
    /// from it stay recognisable by magnitude even where the arithmetic no longer produces the sentinel exactly.
    static func isUnbounded(_ rect: NSRect) -> Bool {
        rect.isInfinite || !rect.height.isFinite || rect.height >= .greatestFiniteMagnitude / 2
    }

    /// Resets the record of committed pixels so the next layout pass re-dirties the entire viewport.
    ///
    /// Call whenever previously committed pixels may no longer match `visibleFragments` - the layout pass does
    /// this itself when the fragment list changes; view-side callers must do it when the backing store may have
    /// been discarded or resized out from under us (frame size changes, moving between windows).
    public func invalidateRasterizedRegion() {
        rasterizedRegion = .null
    }

    /// Strips thinner than this can't produce a blank a user could see, and demanding them every pass would
    /// turn sub-point scroll offsets and pixel-alignment rounding into a permanent per-tick repaint.
    static let rasterizedCoverageEpsilon: CGFloat = 0.5

    /// Records that `rect` was just rasterized from the current `visibleFragments`.
    ///
    /// Only the on-screen part of `rect` is credited: the backing store holds screen pixels, so a draw that
    /// reaches past the viewport leaves nothing behind there. The region is kept as a single rect, so it may
    /// only grow by rects that touch it - unioning a disjoint rect would claim the never-drawn gap between the
    /// two as committed. A disjoint commit replaces the old claim outright: the only consumer compares the
    /// region against the *current* viewport, so the rect drawn most recently is strictly more useful than any
    /// stale claim. The abandoned claim only costs a redundant redraw if revisited, never a blank.
    func recordRasterized(_ rect: NSRect) {
        let viewport = viewportRect()
        let committed = viewport.isEmpty ? rect : rect.intersection(viewport)
        guard !committed.isEmpty else { return }
        if rasterizedRegion.isNull || rasterizedRegion.intersects(committed.insetBy(dx: -1, dy: -1)) {
            rasterizedRegion = rasterizedRegion.union(committed)
        } else {
            rasterizedRegion = committed
        }
    }

    /// Drops committed pixels that are no longer inside `viewport`.
    ///
    /// Committed pixels are recorded in document coordinates, but they live in a *screen* backing store: what
    /// scrolls out of the clip view is gone, and revisiting those rows later means drawing them again. Without
    /// this the single unioned rect grows across scroll positions and ends up claiming rows whose pixels were
    /// discarded long ago - which reads as "already committed" and leaves them blank.
    func retainRasterized(within viewport: NSRect) {
        guard !rasterizedRegion.isNull, !viewport.isEmpty else { return }
        let retained = rasterizedRegion.intersection(viewport)
        rasterizedRegion = retained.isEmpty ? .null : retained
    }

    /// Drops the y-band `minY..<maxY` from the committed claim, keeping whichever side of it survives intact.
    ///
    /// Used when a layout pass changed the fragments inside that band and could not dirty it - those pixels no
    /// longer match the current fragment list and no repaint is owed for them. A single rect can't represent a
    /// hole, so the wider surviving side is kept and the rest is forgotten.
    func invalidateRasterized(band minY: CGFloat, _ maxY: CGFloat) {
        guard !rasterizedRegion.isNull, maxY > minY else { return }
        let region = rasterizedRegion
        guard region.maxY > minY, region.minY < maxY else { return } // band misses the claim entirely
        let above = minY - region.minY
        let below = region.maxY - maxY
        if above <= 0 && below <= 0 {
            rasterizedRegion = .null
        } else if above >= below {
            rasterizedRegion = NSRect(x: region.minX, y: region.minY, width: region.width, height: above)
        } else {
            rasterizedRegion = NSRect(x: region.minX, y: maxY, width: region.width, height: below)
        }
    }

    /// The rect of `layoutView` that is physically exposed inside its host, in the layout view's own
    /// coordinates - the pixels that must always be backed by a committed draw.
    ///
    /// Derived from the host's geometry, which AppKit owns and which is therefore independent of anything this
    /// pipeline computes, and never from the layout view's own bounds: a document view's bounds *are* the whole
    /// document, so a bounds-derived answer would let a layout pass - which grows to cover whatever this
    /// returns - expand to the entire document. It deliberately does not consult `layoutView.visibleRect`
    /// either, which a misreporting override could use to silently define away pixels that must be painted.
    ///
    /// The immediate superview's rect bounds the exposed region for every host shape: for a document view it is
    /// exactly the clip view's viewport, and for any other host it is an over-claim, which costs redundant
    /// draws but can never hide a visible row. A clip view further up the chain narrows it again, and the
    /// result is clamped to the layout view's bounds because nothing outside them can be drawn.
    ///
    /// A view with no superview has no host and therefore no viewport, and the answer is empty rather than
    /// fabricated. Every consumer reads an empty viewport as "unknown": ``layoutPassRects(for:)`` leaves the
    /// requested rect alone, and ``applyRedrawDecision(forceLayout:viewport:)`` skips its strip work.
    func viewportRect() -> NSRect {
        guard let layoutView, let superview = layoutView.superview else { return .zero }
        var viewport = superview.convert(superview.bounds, to: layoutView).intersection(layoutView.bounds)
        if !(superview is NSClipView), let clipView = layoutView.enclosingScrollView?.contentView {
            viewport = viewport.intersection(clipView.convert(clipView.bounds, to: layoutView))
        }
        // Rects that don't meet intersect to `.null`, whose infinite origin would leak into anything derived
        // from it. "No viewport" has exactly one representation here.
        return viewport.isEmpty ? .zero : viewport
    }

    /// The region a redraw decision has to reason about: the live viewport plus whatever band has been published
    /// to AppKit as `preparedContentRect`.
    ///
    /// The prepared rect is a promise that the band is fully rendered, and AppKit may blit it during a fast
    /// scroll without asking us to draw. A fragment that changes inside that band while it sits outside the
    /// viewport therefore leaves pixels AppKit will happily reuse, so the band counts as drawable. Clamped to the
    /// layout view's bounds because `preparedContentRect` defaults to `visibleRect`, which is infinite for a
    /// windowless view.
    func drawableRect(viewport: NSRect) -> NSRect {
        guard let layoutView else { return viewport }
        let bounds = layoutView.bounds
        let base = viewport.isEmpty ? bounds : viewport
        let prepared = layoutView.preparedContentRect.intersection(bounds)
        return prepared.isEmpty ? base : base.union(prepared)
    }

    /// Dirties the parts of `viewport` that `rasterizedRegion` does not cover. The region is a single rect, so
    /// the uncovered remainder is at most four edge strips - dirtying only those keeps the follow-up draw
    /// proportional to the revealed area (a few points per scroll tick) instead of the whole viewport.
    func setNeedsDisplayForUnrasterized(viewport: NSRect) {
        guard let layoutView else { return }
        let epsilon = Self.rasterizedCoverageEpsilon
        let covered = rasterizedRegion.isNull ? .zero : rasterizedRegion.intersection(viewport)
        guard !covered.isEmpty else {
            layoutView.setNeedsDisplay(viewport)
            return
        }
        if covered.minY - viewport.minY > epsilon {
            layoutView.setNeedsDisplay(
                NSRect(x: viewport.minX, y: viewport.minY, width: viewport.width, height: covered.minY - viewport.minY)
            )
        }
        if viewport.maxY - covered.maxY > epsilon {
            layoutView.setNeedsDisplay(
                NSRect(x: viewport.minX, y: covered.maxY, width: viewport.width, height: viewport.maxY - covered.maxY)
            )
        }
        if covered.minX - viewport.minX > epsilon {
            layoutView.setNeedsDisplay(
                NSRect(x: viewport.minX, y: viewport.minY, width: covered.minX - viewport.minX, height: viewport.height)
            )
        }
        if viewport.maxX - covered.maxX > epsilon {
            layoutView.setNeedsDisplay(
                NSRect(x: covered.maxX, y: viewport.minY, width: viewport.maxX - covered.maxX, height: viewport.height)
            )
        }
    }

    /// Decides what this pass has to repaint, and keeps `rasterizedRegion` an honest record of the pixels that
    /// are committed on screen for the *current* fragment list.
    ///
    /// Three independent reasons to dirty something, cheapest first:
    ///   * a forced pass re-typeset everything, so nothing on screen can be trusted;
    ///   * the fragment list changed - but only inside a bounded y-band, and only that band needs pixels
    ///     (steady scrolling changes the list at the edges of the padded layout band, far outside the
    ///     viewport, where repainting would be pure waste);
    ///   * the viewport contains pixels no draw ever committed - the reveal edge of a scroll. An unchanged
    ///     fragment list can never rule this out: fragment positions are document coordinates, so a pure
    ///     scroll yields an identical list while the newly exposed rows have never been rasterized.
    ///
    /// A text view that renders through tiles takes ``applyTiledRedrawDecision(forceLayout:viewport:pass:bands:)``
    /// instead: its pixels outlive the viewport, so there is no record of committed pixels to keep. So do the views
    /// following its layout (see ``TextTileFollower``).
    ///
    /// Called outside `layoutLock` because `setNeedsDisplay` may trigger a synchronous display.
    /// - Parameters:
    ///   - pass: The rect the pass laid out.
    ///   - bands: The y-bands the pass walked.
    func applyRedrawDecision(forceLayout: Bool, viewport: NSRect, pass: NSRect, bands: LayoutPassBands) {
        if let tiles = activeTileManager {
            applyTiledRedrawDecision(tiles, forceLayout: forceLayout, viewport: viewport, pass: pass, bands: bands)
            return
        }
        retainRasterized(within: viewport)

        guard !forceLayout else {
            invalidateRasterizedRegion()
            layoutView?.needsDisplay = true
            return
        }

        // Fragments outside the drawable region can change freely - nothing was ever painted for them. Only
        // changes overlapping it need pixels, and during steady scrolling there are none: the list churns at
        // the edges of the padded layout band, hundreds of points away from the viewport.
        let drawable = drawableRect(viewport: viewport)
        if let band = changedFragmentBand(in: drawable) {
            guard let layoutView else {
                // No view to dirty and no draw to come: the claim is the only record left, and inside the band
                // it is now false.
                invalidateRasterized(band: band.minY, band.maxY)
                return
            }
            // The claim keeps the band. Dirtying it here *is* the guarantee the claim stands for, and the part
            // of the band the claim covers lies inside the viewport, which is where AppKit honours dirty rects.
            // Punching a hole instead would cost the whole side of the claim a single rect cannot keep - which
            // the strip pass below would then re-dirty as "never rasterized", turning a two-line edit in
            // mid-viewport into a repaint of half the viewport.
            layoutView.setNeedsDisplay(
                NSRect(x: drawable.minX, y: band.minY, width: drawable.width, height: band.maxY - band.minY)
            )
        }

        if !viewport.isEmpty {
            setNeedsDisplayForUnrasterized(viewport: viewport)
        }
    }

    /// The redraw decision for a text view that renders through tiles.
    ///
    /// The tiles are brought in line with the pass first. Tiles it creates are entirely dirty; the ones it keeps
    /// showed the previous pass's fragments, so the band where this pass's fragments differ is repainted across
    /// them - all of them, not just the on-screen ones, because tiles keep their pixels when they scroll away. A
    /// forced pass re-typeset everything, so every tile is repainted. The tiles of the views following the layout
    /// (see ``TextTileFollower``) get the same treatment.
    private func applyTiledRedrawDecision(
        _ tiles: TextTileManager,
        forceLayout: Bool,
        viewport: NSRect,
        pass: NSRect,
        bands: LayoutPassBands
    ) {
        let kept = tiles.updateCoverage(viewport: viewport, pass: pass, bands: bands)
        if forceLayout {
            tiles.setNeedsDisplayAll()
        } else if let kept, let band = changedFragmentBand(in: kept) {
            tiles.setNeedsDisplay(NSRect(x: kept.minX, y: band.minY, width: kept.width, height: band.maxY - band.minY))
        }
        updateTileFollowers(forceLayout: forceLayout, viewport: viewport, pass: pass, bands: bands)
    }

    /// Brings the tiles in line with the text view's current geometry outside a layout pass - after its frame
    /// changed width, which resizes the edge column. The fragments are those of the last pass.
    func refreshTileCoverage() {
        guard let tiles = activeTileManager else { return }
        let viewport = viewportRect()
        _ = tiles.updateCoverage(viewport: viewport, pass: viewport, bands: lastPassBands)
    }

    /// The document y-band spanned by a set of invalidated lines, accumulated while they are marked.
    ///
    /// Line storage y positions exclude view zone whitespace, so the band is shifted back into document space
    /// using the whitespace above its first and last line. That whitespace is monotonic in line index, so those
    /// two lookups bound every line between them.
    struct InvalidatedLineBand {
        var minY: CGFloat = .greatestFiniteMagnitude
        var maxY: CGFloat = -CGFloat.greatestFiniteMagnitude
        var firstIndex: Int = Int.max
        var lastIndex: Int = Int.min

        var isEmpty: Bool { maxY <= minY }

        mutating func mark(_ position: TextLineStorage<TextLine>.TextLinePosition) {
            position.data.setNeedsLayout()
            extend(yPos: position.yPos, height: position.height, index: position.index)
        }

        /// Marks a line from a span walk. A line whose ``TextLine`` hasn't been created has no layout to invalidate,
        /// and the walk leaves it uncreated.
        mutating func mark(_ span: TextLineStorage<TextLine>.LineSpan, in storage: TextLineStorage<TextLine>) {
            storage.existingData(at: span.handle)?.setNeedsLayout()
            extend(yPos: span.yPos, height: span.height, index: span.index)
        }

        private mutating func extend(yPos: CGFloat, height: CGFloat, index: Int) {
            minY = Swift.min(minY, yPos)
            maxY = Swift.max(maxY, yPos + height)
            firstIndex = Swift.min(firstIndex, index)
            lastIndex = Swift.max(lastIndex, index)
        }
    }

    /// Dirties only the band the invalidated lines occupy, instead of the whole view.
    ///
    /// The band covers those lines at their *current* positions. Re-typesetting one of them can change its
    /// height and shift every line below it, which this band does not cover - that movement is caught by the
    /// layout pass, whose ``changedFragmentBand(in:)`` charges every fragment whose identity or position differs
    /// from the previous pass and extends the dirty band down to the bottom of the drawable region. Every caller
    /// here also sets `needsLayout`, and AppKit's update cycle runs layout before display, so that pass always
    /// happens before the pixels are asked for. An invalidation that marked no line dirties everything: there is
    /// no band to scope the redraw to, and blanks are unacceptable.
    func setNeedsDisplay(for band: InvalidatedLineBand) {
        guard let layoutView else { return }
        guard !band.isEmpty else {
            layoutView.needsDisplay = true
            return
        }
        var minY = band.minY
        var maxY = band.maxY
        if !viewZones.zones.isEmpty {
            minY += viewZones.whitespaceHeightBeforeLine(band.firstIndex)
            maxY += viewZones.whitespaceHeightBeforeLine(band.lastIndex)
        }
        let bounds = layoutView.bounds
        layoutView.setNeedsDisplay(NSRect(x: bounds.minX, y: minY, width: bounds.width, height: maxY - minY))
    }

    /// Invalidates layout for the given rect.
    ///
    /// - Parameter rect: The rect to invalidate, in **document** coordinates - view zone whitespace included,
    ///   the same space every other rect-taking API here uses and the space ``setNeedsDisplay(for:)`` dirties
    ///   in. Line storage y positions exclude that whitespace, so the selection is widened by it and each
    ///   candidate line is then filtered against `rect` in document space.
    public func invalidateLayoutForRect(_ rect: NSRect) {
        var band = InvalidatedLineBand()
        let hasViewZones = !viewZones.zones.isEmpty
        // Whitespace only ever pushes a line further down the document, so a line inside `rect` sits no lower
        // than `rect.minY` and no higher than `rect.maxY` in line storage space: this window is a superset.
        let queryMinY = hasViewZones ? max(rect.minY - viewZones.totalHeight, 0) : rect.minY
        for linePosition in lineStorage.linesStartingAt(queryMinY, until: rect.maxY) {
            if hasViewZones {
                // Document y is monotonic in line index, so the first line past `rect` ends the walk.
                let documentY = linePosition.yPos + viewZones.whitespaceHeightBeforeLine(linePosition.index)
                if documentY >= rect.maxY { break }
                guard documentY + linePosition.height > rect.minY else { continue }
            }
            band.mark(linePosition)
        }
        layoutRevision &+= 1

        layoutView?.needsLayout = true
        setNeedsDisplay(for: band)
    }

    /// Invalidates layout for the given range of text.
    /// - Parameter range: The range of text to invalidate.
    public func invalidateLayoutForRange(_ range: NSRange) {
        var band = InvalidatedLineBand()
        if range.isEmpty {
            // For zero-length ranges (e.g. cursor position after insert/delete at a point), invalidate the line
            // containing the location.
            if let linePosition = lineStorage.getLine(atOffset: range.location) {
                band.mark(linePosition)
            } else if let lastLine = lineStorage.last {
                // If we can't find a line at the offset (e.g. offset == length), invalidate the last line.
                band.mark(lastLine)
            }
        } else {
            for span in lineStorage.lineSpans(in: range) {
                band.mark(span, in: lineStorage)
            }
        }

        // Special case where we've deleted from the very end, `linesInRange` correctly does not return any lines
        // So we need to invalidate the last line specifically.
        if range.location == textStorage?.length, let lastLine = lineStorage.last {
            band.mark(lastLine)
        }
        layoutRevision &+= 1

        layoutView?.needsLayout = true
        setNeedsDisplay(for: band)
    }

    public func setNeedsLayout() {
        needsLayout = true
        layoutRevision &+= 1
        lastCompletedPassGeneration = 0
        layoutView?.needsLayout = true
        layoutView?.needsDisplay = true
    }
}
