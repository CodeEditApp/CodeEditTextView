//
//  TextView+ScrollToVisible.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 6/15/24.
//

import Foundation
import AppKit

extension TextView {
    fileprivate typealias Direction = TextSelectionManager.Direction
    fileprivate typealias TextSelection = TextSelectionManager.TextSelection

    /// Scrolls the upmost selection to the visible rect if `scrollView` is not `nil`.
    public func scrollSelectionToVisible() {
        guard let scrollView, let selection = getSelection() else {
            return
        }

        let offsetToScrollTo = offsetNotPivot(selection)

        // There's a bit of a chicken-and-the-egg issue going on here. We need to know the rect to scroll to, but we
        // can't know the exact rect to make visible without laying out the text. Then, once text is laid out the
        // selection rect may be different again. To solve this, we loop until the frame doesn't change after a layout
        // pass and scroll to that rect.

        var lastFrame: CGRect = .zero
        while let boundingRect = layoutManager.rectForOffset(offsetToScrollTo), lastFrame != boundingRect {
            lastFrame = boundingRect
            layoutManager.layoutLines()
            selectionManager.updateSelectionViews()
            selectionManager.drawSelections(in: visibleRect)
        }
        if lastFrame != .zero {
            scrollView.contentView.scrollToVisible(lastFrame)
        }
    }

    public func scrollToRange(_ range: NSRange) {
        guard let scrollView else { return }

        guard let boundingRect = layoutManager.rectForOffset(range.location) else { return }

        // Check if the range is already visible
        if visibleRect.contains(boundingRect) {
            return // No scrolling needed
        }

        // Calculate the target offset to center the range in the view
        let targetOffset = CGPoint(
            x: max(boundingRect.midX - visibleRect.width / 2, 0),
            y: max(boundingRect.midY - visibleRect.height / 2, 0)
        )

        var lastFrame: CGRect = .zero

        // Set a timeout to avoid a infinite loop
        let timeout: TimeInterval = 0.5
        let startTime = Date()

        // Adjust layout until stable
        while let newRect = layoutManager.rectForOffset(range.location),
              lastFrame != newRect,
              Date().timeIntervalSince(startTime) < timeout {
            lastFrame = newRect
            layoutManager.layoutLines()
            selectionManager.updateSelectionViews()
            selectionManager.drawSelections(in: visibleRect)
        }

        // Scroll to make the range appear in the middle of the screen
        if lastFrame != .zero {
            let animated = false // feature flag
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15 // Adjust duration as needed
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    scrollView.contentView.animator().setBoundsOrigin(targetOffset)
                }
            } else {
                scrollView.contentView.scroll(to: targetOffset)
            }
        }
    }

    /// Get the selection that should be scrolled to visible for the current text selection.
    /// - Returns: The the selection to scroll to.
    private func getSelection() -> TextSelection? {
        selectionManager
            .textSelections
            .sorted(by: { $0.range.max > $1.range.max }) // Get the lowest one.
            .first
    }

    /// Returns the offset that isn't the pivot of the selection.
    /// - Parameter selection: The selection to use.
    /// - Returns: The offset suitable for scrolling to.
    private func offsetNotPivot(_ selection: TextSelection) -> Int {
        guard let pivot = selection.pivot else {
            return selection.range.location
        }
        if selection.range.location == pivot {
            return selection.range.max
        } else {
            return selection.range.location
        }
    }
}
