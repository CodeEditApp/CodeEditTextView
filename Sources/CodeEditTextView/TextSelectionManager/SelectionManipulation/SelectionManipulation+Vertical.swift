//
//  SelectionManipulation+Vertical.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 5/11/24.
//

import Foundation

package extension TextSelectionManager {
    // MARK: - Vertical Methods

    /// Extends a selection from the given offset vertically to the destination.
    /// - Parameters:
    ///   - offset: The offset to extend from.
    ///   - destination: The destination to extend to.
    ///   - up: Set to true if extending up.
    ///   - suggestedXPos: The suggested x position to stick to.
    /// - Returns: The range of the extended selection.
    func extendSelectionVertical(
        from offset: Int,
        destination: Destination,
        up: Bool,
        suggestedXPos: CGFloat?
    ) -> NSRange {
        // If moving up and on first line, jump to beginning of the line
        // If moving down and on last line, jump to end of document.
        if up && layoutManager?.lineStorage.first?.range.contains(offset) ?? false {
            return NSRange(location: 0, length: offset)
        } else if !up && layoutManager?.lineStorage.last?.range.contains(offset) ?? false {
            return NSRange(location: offset, length: (textStorage?.length ?? 0) - offset)
        }

        switch destination {
        case .character:
            return extendSelectionVerticalCharacter(from: offset, up: up, suggestedXPos: suggestedXPos)
        case .word, .line, .visualLine:
            return extendSelectionVerticalLine(from: offset, up: up)
        case .page:
            return extendSelectionPage(from: offset, delta: up ? 1 : -1)
        case .document:
            if up {
                return NSRange(location: 0, length: offset)
            } else {
                return NSRange(location: offset, length: (textStorage?.length ?? 0) - offset)
            }
        }
    }

    /// Extends the selection to the nearest character vertically.
    /// - Parameters:
    ///   - offset: The offset to extend from.
    ///   - up: Set to true if extending up.
    ///   - suggestedXPos: The suggested x position to stick to.
    /// - Returns: The range of the extended selection.
    private func extendSelectionVerticalCharacter(
        from offset: Int,
        up: Bool,
        suggestedXPos: CGFloat?
    ) -> NSRange {
        guard let point = layoutManager?.rectForOffset(offset)?.origin,
              let newOffset = layoutManager?.textOffsetAtPoint(
                CGPoint(
                    x: suggestedXPos == nil ? point.x : suggestedXPos!,
                    y: point.y - (layoutManager?.estimateLineHeight() ?? 2.0)/2 * (up ? 1 : -3)
                )
              ) else {
            return NSRange(location: offset, length: 0)
        }

        return NSRange(
            location: up ? newOffset : offset,
            length: up ? offset - newOffset : newOffset - offset
        )
    }

    /// Extends the selection to the nearest line vertically.
    ///
    /// If moving up and the offset is in the middle of the line, it first extends it to the beginning of the line.
    /// On the second call, it will extend it to the beginning of the previous line. When moving down, the
    /// same thing will happen in the opposite direction.
    ///
    /// - Parameters:
    ///   - offset: The offset to extend from.
    ///   - up: Set to true if extending up.
    ///   - suggestedXPos: The suggested x position to stick to.
    /// - Returns: The range of the extended selection.
    private func extendSelectionVerticalLine(
        from offset: Int,
        up: Bool
    ) -> NSRange {
        // Important distinction here, when moving up/down on a line and in the middle of the line, we move to the
        // beginning/end of the *entire* line, not the line fragment.
        guard let line = layoutManager?.textLineForOffset(offset) else {
            return NSRange(location: offset, length: 0)
        }
        if up && line.range.location != offset {
            return NSRange(location: line.range.location, length: offset - line.index)
        } else if !up && line.range.max - (layoutManager?.detectedLineEnding.length ?? 0) != offset {
            return NSRange(
                location: offset,
                length: line.range.max - offset - (layoutManager?.detectedLineEnding.length ?? 0)
            )
        } else {
            let nextQueryIndex = up ? max(line.range.location - 1, 0) : min(line.range.max, (textStorage?.length ?? 0))
            guard let nextLine = layoutManager?.textLineForOffset(nextQueryIndex) else {
                return NSRange(location: offset, length: 0)
            }
            return NSRange(
                location: up ? nextLine.range.location : offset,
                length: up
                ? offset - nextLine.range.location
                : nextLine.range.max - offset - (layoutManager?.detectedLineEnding.length ?? 0)
            )
        }
    }

    /// Extends a selection one "page" long.
    /// - Parameters:
    ///   - offset: The location to start extending the selection from.
    ///   - delta: The direction the selection should be extended. `1` for forwards, `-1` for backwards.
    /// - Returns: The range of the extended selection.
    private func extendSelectionPage(from offset: Int, delta: Int) -> NSRange {
        guard let textView, let endOffset = layoutManager?.textOffsetAtPoint(
            CGPoint(
                x: delta > 0 ? textView.frame.maxX : textView.frame.minX,
                y: delta > 0 ? textView.frame.maxY : textView.frame.minY
            )
        ) else {
            return NSRange(location: offset, length: 0)
        }
        return endOffset > offset
        ? NSRange(location: offset, length: endOffset - offset)
        : NSRange(location: endOffset, length: offset - endOffset)
    }
}
