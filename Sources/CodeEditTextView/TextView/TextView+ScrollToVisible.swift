//
//  TextView+ScrollToVisible.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 6/15/24.
//

import Foundation

extension TextView {
    /// Scrolls the upmost selection to the visible rect if `scrollView` is not `nil`.
    /// - Parameter updateDirection: (optional) the direction of a change in selection. Used to try and keep
    ///                              contextual portions of the selection in the viewport.
    public func scrollSelectionToVisible(updateDirection: TextSelectionManager.Direction? = nil) {
        guard let scrollView else {
            return
        }

        // There's a bit of a chicken-and-the-egg issue going on here. We need to know the rect to scroll to, but we
        // can't know the exact rect to make visible without laying out the text. Then, once text is laid out the
        // selection rect may be different again. To solve this, we loop until the frame doesn't change after a layout
        // pass and scroll to that rect.

        var lastFrame: CGRect = .zero
        while let boundingRect = getSelectionRect(updateDirection),
              lastFrame != boundingRect {
            lastFrame = boundingRect
            layoutManager.layoutLines()
            selectionManager.updateSelectionViews()
            selectionManager.drawSelections(in: visibleRect)
        }
        if lastFrame != .zero {
            scrollView.contentView.scrollToVisible(lastFrame)
        }
    }

    /// Get the rect that should be scrolled to visible for the current text selection.
    /// - Parameter updateDirection: The direction of the update.
    /// - Returns: The rect of the selection.
    private func getSelectionRect(_ updateDirection: TextSelectionManager.Direction?) -> CGRect? {
        switch updateDirection {
        case .forward, .backward, nil:
            return selectionManager
                .textSelections
                .sorted(by: { $0.boundingRect.origin.y < $1.boundingRect.origin.y })
                .first?
                .boundingRect
        case .up:
            guard let selection = selectionManager
                .textSelections
                .sorted(by: { $0.range.location < $1.range.location }) // Get the highest one.
                .first,
                  let minRect = layoutManager.rectForOffset(selection.range.location) else {
                return nil
            }
            return CGRect(
                origin: minRect.origin,
                size: CGSize(width: selection.boundingRect.width, height: layoutManager.estimateLineHeight())
            )
        case .down:
            guard let selection = selectionManager
                .textSelections
                .sorted(by: { $0.range.max > $1.range.max }) // Get the lowest one.
                .first,
                  let maxRect = layoutManager.rectForOffset(selection.range.max) else {
                return nil
            }
            let lineHeight = layoutManager.estimateLineHeight()
            return CGRect(
                origin: CGPoint(x: selection.boundingRect.origin.x, y: maxRect.maxY - lineHeight),
                size: CGSize(width: selection.boundingRect.width, height: lineHeight)
            )
        }
    }
}
