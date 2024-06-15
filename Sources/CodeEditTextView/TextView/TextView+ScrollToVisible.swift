//
//  TextView+ScrollToVisible.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 6/15/24.
//

import Foundation

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
