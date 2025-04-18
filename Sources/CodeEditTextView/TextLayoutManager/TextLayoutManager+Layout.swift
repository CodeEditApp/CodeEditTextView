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
    ///
    /// ## Overview Of The Layout Routine
    ///
    /// The basic premise of this method is that it loops over all lines in the given rect (defaults to the visible
    /// rect), checks if the line needs a layout calculation, and performs layout on the line if it does.
    ///
    /// The thing that makes this layout method so fast is the second point, checking if a line needs layout. To
    /// determine if a line needs a layout pass, the layout manager can check three things:
    /// - **1** Was the line laid out under the assumption of a different maximum layout width?
    ///   Eg: If wrapping is toggled, and a line was initially long but now needs to be broken, this triggers that
    ///   layout pass.
    /// - **2** Was the line previously not visible? This is determined by keeping a set of visible line IDs. If the
    ///   line does not appear in that set, we can assume it was previously off screen and may need layout.
    /// - **3** Was the line entirely laid out? We break up lines into line fragments. When we do layout, we determine
    ///   all line fragments but don't necessarily place them all in the view. This checks if all line fragments have
    ///   been placed in the view. If not, we need to place them.
    ///
    /// Once it has been determined that a line needs layout, we perform layout by recalculating it's line fragments,
    /// removing all old line fragment views, and creating new ones for the line.
    ///
    /// ## Laziness
    ///
    /// At the end of the layout pass, we clean up any old lines by updating the set of visible line IDs and fragment
    /// IDs. Any IDs that no longer appear in those sets are removed to save resources. This facilitates the text view's
    /// ability to only render text that is visible and saves tons of resources (similar to the lazy loading of
    /// collection or table views).
    ///
    /// The other important lazy attribute is the line iteration. Line iteration is done lazily. As we iterate
    /// through lines and potentially update their heights, the next line is only queried for *after* the updates are
    /// finished.
    ///
    /// ## Reentry
    ///
    /// An important thing to note is that this method cannot be reentered. If a layout pass has begun while a layout
    /// pass is already ongoing, internal data structures will be broken. In debug builds, this is checked with a simple
    /// boolean and assertion.
    ///
    /// To help ensure this property, all view modifications are done in a `CATransaction`. This ensures that only after
    /// we're done inserting and removing line fragment views, does macOS call `layout` on any related views. Otherwise,
    /// we may cause a layout pass when a line fragment view is inserted and cause a reentrance in this method.
    ///
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
            guard linePosition.yPos < maxY else { continue }
            // Three ways to determine if a line needs to be re-calculated.
            let changedWidth = linePosition.data.needsLayout(maxWidth: maxLineLayoutWidth)
            let wasNotVisible = !visibleLineIds.contains(linePosition.data.id)
            let lineNotEntirelyLaidOut = linePosition.height != linePosition.data.lineFragments.height

            if forceLayout || changedWidth || wasNotVisible || lineNotEntirelyLaidOut {
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
}
