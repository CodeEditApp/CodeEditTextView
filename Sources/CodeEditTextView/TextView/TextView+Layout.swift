//
//  TextView+Layout.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 6/15/24.
//

import Foundation

extension TextView {
    override public func layout() {
        super.layout()

        // let currentWidth = layoutManager.wrapLinesWidth
        // let widthChanged = currentWidth != lastKnownLayoutWidth
        // lastKnownLayoutWidth = currentWidth

        // // When the only change is the available layout width (e.g. a split-view panel animating open/close),
        // // every animation frame would otherwise re-lay out all visible lines because `maxLineLayoutWidth` changed.
        // // Coalesce these into a single deferred pass after the width stabilises instead.
        // //
        // // Conditions for deferral:
        // //   • wrap-lines is enabled (non-wrapping text uses .greatestFiniteMagnitude which never changes)
        // //   • the width changed but no explicit content/layout invalidation is pending
        // //   • there are already visible lines (avoids delaying the very first render)
        // if layoutManager.wrapLines
        //     && widthChanged
        //     && !layoutManager.needsLayout
        //     && !layoutManager.visibleLineIds.isEmpty {
        //     pendingWidthRelayout?.cancel()
        //     let task = DispatchWorkItem { [weak self] in
        //         self?.pendingWidthRelayout = nil
        //         self?.layoutManager.layoutLines()
        //         self?.selectionManager.updateSelectionViews(skipTimerReset: true)
        //     }
        //     pendingWidthRelayout = task
        //     // 50 ms coalesces all frames of a typical panel animation (~200 ms)
        //     // while still being imperceptible after the animation completes.
        //     DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: task)
        // } else {
        //     pendingWidthRelayout?.cancel()
        //     pendingWidthRelayout = nil
        //     layoutManager.layoutLines()
        //     selectionManager.updateSelectionViews(skipTimerReset: true)
        // }
        layoutManager.layoutLines()
        selectionManager.updateSelectionViews(skipTimerReset: true)
    }

    open override class var isCompatibleWithResponsiveScrolling: Bool {
        true
    }

    open override func prepareContent(in rect: NSRect) {
        needsLayout = true
        super.prepareContent(in: rect)
    }

    override public func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isSelectable {
            selectionManager.drawSelections(in: dirtyRect)
        }
        layoutManager.drawLineDecorations(in: dirtyRect)
        emphasisManager?.updateLayerBackgrounds()
    }

    override open var isFlipped: Bool {
        true
    }

    override public var visibleRect: NSRect {
        if let scrollView {
            var rect = scrollView.documentVisibleRect
            rect.origin.y += scrollView.contentInsets.top
            return rect.pixelAligned
        } else {
            return super.visibleRect
        }
    }

    public var visibleTextRange: NSRange? {
        let minY = max(visibleRect.minY, 0)
        let maxY = min(visibleRect.maxY, layoutManager.estimatedHeight())
        guard let minYLine = layoutManager.textLineForPosition(minY),
              let maxYLine = layoutManager.textLineForPosition(maxY) else {
            return nil
        }
        return NSRange(
            location: minYLine.range.location,
            length: (maxYLine.range.location - minYLine.range.location) + maxYLine.range.length
        )
    }

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
        var availableSize = scrollView?.contentSize ?? .zero
        availableSize.height -= (scrollView?.contentInsets.top ?? 0) + (scrollView?.contentInsets.bottom ?? 0)

        let extraHeight = availableSize.height * overscrollAmount
        let newHeight = max(layoutManager.estimatedHeight() + extraHeight, availableSize.height, 0)
        let newWidth = layoutManager.estimatedWidth()

        var didUpdate = false

        if newHeight >= availableSize.height && frame.size.height != newHeight {
            frame.size.height = newHeight
            // No need to update layout after height adjustment
        }

        if wrapLines && frame.size.width != availableSize.width {
            frame.size.width = availableSize.width
            didUpdate = true
        } else if !wrapLines && frame.size.width != max(newWidth, availableSize.width) {
            frame.size.width = max(newWidth, availableSize.width)
            didUpdate = true
        }

        if didUpdate {
            needsLayout = true
            needsDisplay = true
            layoutManager.setNeedsLayout()
        }

        if isSelectable {
            selectionManager?.updateSelectionViews()
        }

        return didUpdate
    }
}
