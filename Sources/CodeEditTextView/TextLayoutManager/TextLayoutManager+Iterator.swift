//
//  TextLayoutManager+Iterator.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 8/21/23.
//

import Foundation

public extension TextLayoutManager {
    /// Iterate over all visible lines.
    ///
    /// Visible lines are any lines contained by the rect returned by ``TextLayoutManagerDelegate/visibleRect`` or,
    /// if there is no delegate from `0` to the estimated document height.
    ///
    /// - Returns: An iterator to iterate through all visible lines.
    func visibleLines() -> Iterator {
        let visibleRect = delegate?.visibleRect ?? NSRect(
            x: 0,
            y: 0,
            width: 0,
            height: estimatedHeight()
        )
        return Iterator(minY: max(visibleRect.minY, 0), maxY: max(visibleRect.maxY, 0), layoutManager: self)
    }

    /// Iterate over all lines in the y position range.
    /// - Parameters:
    ///   - minY: The minimum y position to begin at.
    ///   - maxY: The maximum y position to iterate to.
    /// - Returns: An iterator that will iterate through all text lines in the y position range.
    func linesStartingAt(_ minY: CGFloat, until maxY: CGFloat) -> Iterator {
        Iterator(minY: minY, maxY: maxY, layoutManager: self)
    }

    struct Iterator: LazySequenceProtocol, IteratorProtocol {
        typealias TextLinePosition = TextLineStorage<TextLine>.TextLinePosition

        private weak var layoutManager: TextLayoutManager?
        private let minY: CGFloat
        private let maxY: CGFloat
        private var currentPosition: TextLinePosition?

        init(minY: CGFloat, maxY: CGFloat, layoutManager: TextLayoutManager) {
            self.minY = minY
            self.maxY = maxY
            self.layoutManager = layoutManager
        }

        public mutating func next() -> TextLineStorage<TextLine>.TextLinePosition? {
            // Determine the 'visible' line at the next position. This iterator may skip lines that are covered by
            // attachments, so we use the line position's range to get the next position. Once we have the position,
            // we'll create a new one that reflects what we actually want to display.
            // Eg for the following setup:
            // Line 1
            // Line[ 2 <- Attachment start
            // Line 3
            // Line] 4 <- Attachment end
            // The iterator will first return the line 1 position, then, line 2 is queried but has an attachment.
            // So, we extend the line until the end of the attachment (line 4), and return the position extended that
            // far.
            // This retains information line line index and position in the text storage.

            if let currentPosition {
                guard let nextPosition = layoutManager?.lineStorage.getLine(
                    atOffset: currentPosition.range.max + 1
                ), nextPosition.yPos < maxY else {
                    return nil
                }
                self.currentPosition = determineVisiblePosition(for: nextPosition)
                return self.currentPosition
            } else if let position = layoutManager?.lineStorage.getLine(atPosition: minY) {
                currentPosition = determineVisiblePosition(for: position)
                return currentPosition
            }

            return nil
        }

        private func determineVisiblePosition(for originalPosition: TextLinePosition) -> TextLinePosition {
            guard let attachment = layoutManager?.attachments.attachments(startingIn: originalPosition.range).last,
                  attachment.range.max > originalPosition.range.max else {
                // No change, either no attachments or attachment doesn't span multiple lines.
                return originalPosition
            }

            guard let extendedLinePosition = layoutManager?.lineStorage.getLine(atOffset: attachment.range.max) else {
                return originalPosition
            }

            let newPosition = TextLinePosition(
                data: originalPosition.data,
                range: NSRange(start: originalPosition.range.location, end: extendedLinePosition.range.max),
                yPos: originalPosition.yPos,
                height: originalPosition.height,
                index: originalPosition.index
            )

            return determineVisiblePosition(for: newPosition)
        }
    }
}
