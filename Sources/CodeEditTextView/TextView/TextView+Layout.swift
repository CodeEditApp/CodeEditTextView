//
//  TextView+Layout.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 6/15/24.
//

import AppKit

extension TextView {
    override public func layout() {
        super.layout()

        // During responsive scrolling AppKit pre-renders a band that's larger than the current `visibleRect`
        // via `prepareContent(in:)`. If our `layout()` pass then re-runs with just `visibleRect`, the fragments
        // for that buffer are dropped - and a subsequent fast scroll into the buffered band sees blank space
        // until the next layout cycle. Honour `preparedContentRect` (via `preferredLayoutRect`) so the buffer
        // survives the layout pass.
        layoutManager.layoutLines(in: preferredLayoutRect)
        selectionManager.updateSelectionViews(skipTimerReset: true)
    }

    open override class var isCompatibleWithResponsiveScrolling: Bool {
        true
    }

    /// AppKit calls this during responsive scrolling to ask the document view to render content *outside* the
    /// current `visibleRect`, so subsequent fast scrolls can land on already-drawn pixels instead of blank space.
    ///
    /// The default implementation just sets `preparedContentRect` to `rect` (via `super`) and dirties the area,
    /// which means our layout pass - which is keyed off `visibleRect`, not the prepared rect - never produces
    /// fragments for that buffer band. The visible symptom is a flash of blank space at the leading edge of the
    /// viewport during fast scrolls.
    ///
    /// We expand `rect` to also include the current `visibleRect` (defensive - AppKit's rect should already cover
    /// it, but the union is cheap insurance) and run a layout pass against that union so `visibleFragments`
    /// covers everything AppKit is about to ask us to draw. We then forward to `super` so AppKit records the
    /// prepared rect and dirties it for drawing.
    open override func prepareContent(in rect: NSRect) {
        // Lay out fragments for the prepared band synchronously (unioned with `visibleRect` so the pass can
        // never shrink viewport coverage). `layoutLines(in:)` is reentrancy-guarded by `layoutLock` and
        // `isInTransaction`, so calling it here is safe even if AppKit invokes us mid-scroll.
        layoutManager?.layoutLines(in: rect.union(visibleRect))
        selectionManager?.updateSelectionViews(skipTimerReset: true)
        // Forward AppKit's rect unmodified. `preparedContentRect` is a promise that the area is fully rendered -
        // enlarging it here would claim regions this pipeline may never have rasterized (the layout pass above
        // may have been skipped by its reentrancy guard), and AppKit would then blit blank pixels from that
        // band instead of asking us to draw.
        super.prepareContent(in: rect)
    }

    override public func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Decorations are a line-background underlay. Draw first so text/selections sit on top.
        layoutManager.drawLineDecorations(in: dirtyRect)
        // Selection fills draw under the glyphs so the caret sits inside the highlight.
        if isSelectable {
            selectionManager.drawSelections(in: dirtyRect)
        }
        // Draw every visible fragment that intersects this dirty rect. Replaces the per-fragment NSView+draw(_:) path.
        layoutManager.drawVisibleFragments(in: dirtyRect)
        emphasisManager?.updateLayerBackgrounds()
    }

    override open var isFlipped: Bool {
        true
    }

    /// The region of this view that is physically on screen inside the enclosing clip view.
    ///
    /// AppKit clips both dirty-rect delivery *and* drawing to this rect, so it must report the truth: anything
    /// it omits can never be painted, and anything it over-claims is painted where nothing is visible. It is
    /// therefore exactly `documentVisibleRect` (the clip view's bounds in document coordinates) clipped to this
    /// view's own bounds. In particular the enclosing scroll view's `contentInsets` must NOT be applied here -
    /// insets do not shrink the clip view, they only shift the scrollable range, and the whole inset band is
    /// live, composited screen area. Callers that want the region not covered by the host's chrome (scrolling a
    /// caret into view, for instance) want ``unobscuredVisibleRect`` instead.
    /// With no host, AppKit answers `.infinite`. That value is deliberately left alone: consumers that ask "what
    /// text is live" (``visibleTextRange``, and through it the selection fill rects) read it as "all of it",
    /// which is what an unhosted view needs, while the layout pass reads it as "no clipping information" and
    /// declines to grow to the document - see ``TextLayoutManager/layoutPassRects(for:)``.
    override public var visibleRect: NSRect {
        guard let scrollView else {
            return super.visibleRect
        }
        return scrollView.documentVisibleRect.intersection(bounds)
    }

    /// The part of ``visibleRect`` that isn't sitting underneath the host's chrome (tab bar, breadcrumbs, find
    /// panel).
    ///
    /// The chrome covers the outer `contentInsets` of the *clip view*, so the unobscured region is that inset
    /// rectangle of the clip view's own bounds, mapped into this view's coordinates and clipped to what is
    /// actually on screen. Subtracting the insets from ``visibleRect`` instead would double-count them wherever
    /// the clip view has already been clamped: at the top rest position the clip origin sits at
    /// `-contentInsets.top`, so ``visibleRect`` - which is intersected with this view's bounds - has already
    /// dropped the inset band and document row 0 is fully readable.
    ///
    /// Use this for "is this actually where the user is looking" decisions (scroll-into-view, centering).
    /// Never use it to decide which pixels need painting: those pixels are on screen and must be drawn.
    public var unobscuredVisibleRect: NSRect {
        let rect = visibleRect
        guard let scrollView, let clipView = superview as? NSClipView else { return rect }
        let insets = scrollView.contentInsets
        let clipBounds = clipView.bounds
        let unobscuredInClip = NSRect(
            x: clipBounds.minX + insets.left,
            y: clipBounds.minY + insets.top,
            width: clipBounds.width - insets.left - insets.right,
            height: clipBounds.height - insets.top - insets.bottom
        )
        guard unobscuredInClip.width > 0, unobscuredInClip.height > 0 else { return rect }
        let unobscured = clipView.convert(unobscuredInClip, to: self).intersection(rect)
        // An empty intersection means the chrome covers the whole viewport; callers need a rect they can
        // measure against, and the visible rect is the only honest one left.
        return unobscured.isEmpty ? rect : unobscured
    }

    public var visibleTextRange: NSRange? {
        visibleTextRange(verticalPadding: 0)
    }

    /// The range of text overlapping the visible rect, extended by `verticalPadding` points above and
    /// below.
    ///
    /// Use a padding of at least the layout manager's `verticalLayoutPadding` for work that should stay
    /// ahead of the reveal edge during scrolling or animated resizes (like syntax highlighting), so
    /// newly exposed lines arrive already processed instead of triggering a second pass per frame.
    /// - Parameter verticalPadding: Points to extend the visible rect by, on both ends.
    /// - Returns: The text range overlapping the extended rect, or nil if it couldn't be computed.
    public func visibleTextRange(verticalPadding: CGFloat) -> NSRange? {
        let minY = max(visibleRect.minY - verticalPadding, 0)
        let maxY = min(visibleRect.maxY + verticalPadding, layoutManager.estimatedHeight())
        guard let minYLine = layoutManager.textLineForPosition(minY),
              let maxYLine = layoutManager.textLineForPosition(maxY) else {
            return nil
        }
        return NSRange(
            location: minYLine.range.location,
            length: (maxYLine.range.location - minYLine.range.location) + maxYLine.range.length
        )
    }

    /// Brings layout and the view's frame up to date with the current viewport.
    ///
    /// Unconditional: every call runs a pass. Hosts that drive this from their own scroll observer get one pass
    /// per notification, including the duplicate `boundsDidChange` AppKit posts for a fractional clip origin -
    /// the view's own observers (``setUpScrollListeners(scrollView:)``) coalesce that duplicate away.
    public func updatedViewport(_ newRect: CGRect) {
        if !updateFrameIfNeeded() {
            layoutManager.layoutLines()
        }
        inputContext?.invalidateCharacterCoordinates()
    }

    /// Updates the view's frame if needed depending on wrapping lines, a new maximum width, or changed available size.
    /// - Returns: Whether or not the view was updated.
    @discardableResult
    public func updateFrameIfNeeded() -> Bool {
        guard let scrollView else {
            // Without an enclosing scroll view there is no viewport to size against - the frame is managed
            // externally, and treating the available size as zero would collapse a wrap-enabled view's width.
            if isSelectable {
                selectionManager?.updateSelectionViews()
            }
            return false
        }
        var availableSize = scrollView.contentSize
        availableSize.height -= scrollView.contentInsets.top + scrollView.contentInsets.bottom

        let extraHeight = availableSize.height * overscrollAmount
        let newHeight = max(layoutManager.estimatedHeight() + extraHeight, availableSize.height, 0)
        let newWidth = layoutManager.estimatedWidth()

        var didUpdate = false

        if newHeight >= availableSize.height && frame.size.height != newHeight {
            frame.size.height = newHeight
            // No need to update layout after height adjustment
        }

        // Track whether this is a wrap-mode width change. Wrapping width changes invalidate per-line typesetting
        // (the line break boundaries depend on the canvas width). Non-wrapping width changes only resize the scrollable
        // canvas - the laid-out fragments are still valid and re-typesetting them is wasted work that defeats the
        // hot-path append-only layout for the next frame.
        var wrappingWidthChanged = false
        if wrapLines && frame.size.width != availableSize.width {
            frame.size.width = availableSize.width
            didUpdate = true
            wrappingWidthChanged = true
        } else if !wrapLines && frame.size.width != max(newWidth, availableSize.width) {
            frame.size.width = max(newWidth, availableSize.width)
            didUpdate = true
        }

        if didUpdate {
            needsLayout = true
            needsDisplay = true
            // The frame change may have recreated the backing store; committed-pixel records no longer hold.
            layoutManager.invalidateRasterizedRegion()
            // Only force a full re-layout when wrapping is on - that's the case where line breaks must be recalculated
            // for the new width. In non-wrap mode the canvas just got wider/narrower; existing fragments stay valid.
            if wrappingWidthChanged {
                layoutManager.setNeedsLayout()
            }
        }

        if isSelectable {
            selectionManager?.updateSelectionViews()
        }

        return didUpdate
    }
}
