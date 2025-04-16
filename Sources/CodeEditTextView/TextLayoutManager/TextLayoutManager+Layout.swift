//
//  TextLayoutManager+ensureLayout.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 4/7/25.
//

import AppKit

extension TextLayoutManager {
    /// Contains all data required to perform layout on a text line.
    private struct LineLayoutData {
        let minY: CGFloat
        let maxY: CGFloat
        let maxWidth: CGFloat
    }

    /// Asserts that the caller is not in an active layout pass.
    /// See docs on ``isInLayout`` for more details.
    private func assertNotInLayout() {
#if DEBUG // This is redundant, but it keeps the flag debug-only too which helps prevent misuse.
        assert(!isInLayout, "layoutLines called while already in a layout pass. This is a programmer error.")
#endif
    }

    // MARK: - Layout Lines

    /// Lays out all visible lines
    /// - Warning: This is probably not what you're looking for. If you need to invalidate layout, or update lines, this
    ///            is not the way to do so. This should only be called when macOS performs layout.
    public func layoutLines(in rect: NSRect? = nil) { // swiftlint:disable:this function_body_length
        assertNotInLayout()
        guard let visibleRect = rect ?? delegate?.visibleRect,
              !isInTransaction,
              let textStorage else {
            return
        }

        // The macOS may call `layout` on the textView while we're laying out fragment views. This ensures the view
        // tree modifications caused by this method are atomic, so macOS won't call `layout` while we're already doing
        // that
        CATransaction.begin()
#if DEBUG
        isInLayout = true
#endif

        let minY = max(visibleRect.minY - verticalLayoutPadding, 0)
        let maxY = max(visibleRect.maxY + verticalLayoutPadding, 0)
        let originalHeight = lineStorage.height
        var usedFragmentIDs = Set<UUID>()
        var forceLayout: Bool = needsLayout
        var newVisibleLines: Set<TextLine.ID> = []
        var yContentAdjustment: CGFloat = 0
        var maxFoundLineWidth = maxLineWidth

        // Layout all lines, fetching lines lazily as they are laid out.
        for linePosition in lineStorage.linesStartingAt(minY, until: maxY).lazy {
            guard linePosition.yPos < maxY else { break }
            if forceLayout
                || linePosition.data.needsLayout(maxWidth: maxLineLayoutWidth)
                || !visibleLineIds.contains(linePosition.data.id) {
                let lineSize = layoutLine(
                    linePosition,
                    textStorage: textStorage,
                    layoutData: LineLayoutData(minY: minY, maxY: maxY, maxWidth: maxLineLayoutWidth),
                    laidOutFragmentIDs: &usedFragmentIDs
                )
                if lineSize.height != linePosition.height {
                    lineStorage.update(
                        atOffset: linePosition.range.location,
                        delta: 0,
                        deltaHeight: lineSize.height - linePosition.height
                    )
                    // If we've updated a line's height, force re-layout for the rest of the pass.
                    forceLayout = true

                    if linePosition.yPos < minY {
                        // Adjust the scroll position by the difference between the new height and old.
                        yContentAdjustment += lineSize.height - linePosition.height
                    }
                }
                if maxFoundLineWidth < lineSize.width {
                    maxFoundLineWidth = lineSize.width
                }
            } else {
                // Make sure the used fragment views aren't dequeued.
                usedFragmentIDs.formUnion(linePosition.data.lineFragments.map(\.data.id))
            }
            newVisibleLines.insert(linePosition.data.id)
        }

#if DEBUG
        isInLayout = false
#endif
        // Enqueue any lines not used in this layout pass.
        viewReuseQueue.enqueueViews(notInSet: usedFragmentIDs)

        // Update the visible lines with the new set.
        visibleLineIds = newVisibleLines

        // The delegate methods below may call another layout pass, make sure we don't send it into a loop of forced
        // layout.
        needsLayout = false

        // Commit the view tree changes we just made.
        CATransaction.commit()

        // These are fine to update outside of `isInLayout` as our internal data structures are finalized at this point
        // so laying out again won't break our line storage or visible line.

        if maxFoundLineWidth > maxLineWidth {
            maxLineWidth = maxFoundLineWidth
        }

        if yContentAdjustment != 0 {
            delegate?.layoutManagerYAdjustment(yContentAdjustment)
        }

        if originalHeight != lineStorage.height || layoutView?.frame.size.height != lineStorage.height {
            delegate?.layoutManagerHeightDidUpdate(newHeight: lineStorage.height)
        }
    }

    // MARK: - Layout Single Line

    /// Lays out a single text line.
    /// - Parameters:
    ///   - position: The line position from storage to use for layout.
    ///   - textStorage: The text storage object to use for text info.
    ///   - layoutData: The information required to perform layout for the given line.
    ///   - laidOutFragmentIDs: Updated by this method as line fragments are laid out.
    /// - Returns: A `CGSize` representing the max width and total height of the laid out portion of the line.
    private func layoutLine(
        _ position: TextLineStorage<TextLine>.TextLinePosition,
        textStorage: NSTextStorage,
        layoutData: LineLayoutData,
        laidOutFragmentIDs: inout Set<UUID>
    ) -> CGSize {
        let lineDisplayData = TextLine.DisplayData(
            maxWidth: layoutData.maxWidth,
            lineHeightMultiplier: lineHeightMultiplier,
            estimatedLineHeight: estimateLineHeight()
        )

        let line = position.data
        if let renderDelegate {
            renderDelegate.prepareForDisplay(
                textLine: line,
                displayData: lineDisplayData,
                range: position.range,
                stringRef: textStorage,
                markedRanges: markedTextManager.markedRanges(in: position.range),
                breakStrategy: lineBreakStrategy
            )
        } else {
            line.prepareForDisplay(
                displayData: lineDisplayData,
                range: position.range,
                stringRef: textStorage,
                markedRanges: markedTextManager.markedRanges(in: position.range),
                breakStrategy: lineBreakStrategy
            )
        }

        if position.range.isEmpty {
            return CGSize(width: 0, height: estimateLineHeight())
        }

        var height: CGFloat = 0
        var width: CGFloat = 0
        let relativeMinY = max(layoutData.minY - position.yPos, 0)
        let relativeMaxY = max(layoutData.maxY - position.yPos, relativeMinY)

        for lineFragmentPosition in line.lineFragments.linesStartingAt(
            relativeMinY,
            until: relativeMaxY
        ) {
            let lineFragment = lineFragmentPosition.data

            layoutFragmentView(for: lineFragmentPosition, at: position.yPos + lineFragmentPosition.yPos)

            width = max(width, lineFragment.width)
            height += lineFragment.scaledHeight
            laidOutFragmentIDs.insert(lineFragment.id)
        }

        return CGSize(width: width, height: height)
    }

    // MARK: - Layout Fragment

    /// Lays out a line fragment view for the given line fragment at the specified y value.
    /// - Parameters:
    ///   - lineFragment: The line fragment position to lay out a view for.
    ///   - yPos: The y value at which the line should begin.
    private func layoutFragmentView(
        for lineFragment: TextLineStorage<LineFragment>.TextLinePosition,
        at yPos: CGFloat
    ) {
        let view = viewReuseQueue.getOrCreateView(forKey: lineFragment.data.id) {
            renderDelegate?.lineFragmentView(for: lineFragment.data) ?? LineFragmentView()
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setLineFragment(lineFragment.data)
        view.frame.origin = CGPoint(x: edgeInsets.left, y: yPos)
        layoutView?.addSubview(view)
        view.needsDisplay = true
    }

    /// Invalidates and prepares a line position for display.
    /// - Parameter position: The line position to prepare.
    /// - Returns: The height of the newly laid out line and all it's fragments.
    func preparePositionForDisplay(_ position: TextLineStorage<TextLine>.TextLinePosition) -> CGFloat {
        guard let textStorage else { return 0 }
        let displayData = TextLine.DisplayData(
            maxWidth: maxLineLayoutWidth,
            lineHeightMultiplier: lineHeightMultiplier,
            estimatedLineHeight: estimateLineHeight()
        )
        position.data.prepareForDisplay(
            displayData: displayData,
            range: position.range,
            stringRef: textStorage,
            markedRanges: markedTextManager.markedRanges(in: position.range),
            breakStrategy: lineBreakStrategy
        )
        var height: CGFloat = 0
        for fragmentPosition in position.data.lineFragments {
            height += fragmentPosition.data.scaledHeight
        }
        return height
    }
}
