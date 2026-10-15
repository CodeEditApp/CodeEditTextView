//
//  TextSelectionManager+FillRects.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 10/22/23.
//

import Foundation

extension TextSelectionManager {
    /// Calculate a set of rects for a text selection suitable for filling with the selection color to indicate a
    /// multi-line selection. The returned rects surround all selected line fragments for the given selection,
    /// following the available text layout space, rather than the available selection layout space.
    ///
    /// Results are memoized on the selection itself, keyed on `(range, layoutManager.layoutRevision)`. Repeated draw
    /// calls with no underlying layout change re-use the cached rects directly - no line storage walk, no
    /// `rectForOffset()` calls.
    ///
    /// Cached rects are unclipped: end-of-line rects extend to `CGFloat.greatestFiniteMagnitude`. Each call clips them
    /// to the text's width, so the cache stays valid across width changes that don't bump the layout revision, and
    /// drops the ones outside `rect`. They are not clipped to `rect`: a fill must look the same whichever rect draws
    /// it.
    ///
    /// - Parameters:
    ///   - rect: The bounding rect of available draw space.
    ///   - textSelection: The selection to use.
    /// - Returns: An array of rects that the selection overlaps.
    func getFillRects(in rect: NSRect, for textSelection: TextSelection) -> [CGRect] {
        guard let layoutManager,
              let drawnRange = Self.textRange(in: rect, layoutManager: layoutManager),
              let range = textSelection.range.intersection(drawnRange) else {
            return []
        }

        // Empty selections (cursors) have no fill rects - caret is drawn separately.
        if range.length == 0 {
            return []
        }

        let textWidth = if layoutManager.maxLineLayoutWidth == .greatestFiniteMagnitude {
            layoutManager.maxLineWidth
        } else {
            layoutManager.maxLineLayoutWidth
        }
        let maxWidth = max(textWidth, layoutManager.wrapLinesWidth)
        // Fills are clipped to the text's horizontal extent only. Clipping to `rect` as well, before rounding to whole
        // points, would make a fill's edges depend on the rect being drawn: a redraw that ends half a pixel into a
        // fill would round that edge away and leave a row of gap. The context's clip keeps drawing inside `rect`.
        let textColumn = CGRect(
            x: layoutManager.edgeInsets.left,
            y: -CGFloat.greatestFiniteMagnitude / 2,
            width: maxWidth,
            height: CGFloat.greatestFiniteMagnitude
        )

        let revision = layoutManager.layoutRevision
        let cacheValid = textSelection.cachedFillRectsRange == range
            && textSelection.cachedFillRectsRevision == revision

        if !cacheValid {
            var fillRects: ContiguousArray<CGRect> = []
            fillRects.reserveCapacity(textSelection.cachedFillRects.capacity)

            // Inline scalar form of the selection range - avoids re-reading NSRange location/length per fragment.
            let selStart = range.location
            let selEnd = range.location + range.length

            for linePosition in layoutManager.linesInRange(range) {
                appendFillRects(
                    into: &fillRects,
                    selStart: selStart,
                    selEnd: selEnd,
                    forPosition: linePosition,
                    layoutManager: layoutManager
                )
            }

            textSelection.cachedFillRects = fillRects
            textSelection.cachedFillRectsRange = range
            textSelection.cachedFillRectsRevision = revision
        }

        // Clip and pixel-align per call - the caller's rect must never be baked into the cache.
        var result: [CGRect] = []
        result.reserveCapacity(textSelection.cachedFillRects.count)
        for fillRect in textSelection.cachedFillRects {
            let clipped = fillRect.intersection(textColumn)
            guard !clipped.isNull else { continue }
            let aligned = clipped.pixelAligned
            if aligned.intersects(rect) {
                result.append(aligned)
            }
        }
        return result
    }

    /// The range of text in the visible lines `rect` overlaps, or nil when no line can be found.
    ///
    /// Clipping a selection to this, rather than to whatever is visible, keeps the fill a function of the rect being
    /// drawn: pixels drawn outside the viewport are kept and may scroll into view later. Whole *visible* lines - an
    /// attachment that folds several lines into one is one line here - so a rect whose edge falls inside such a
    /// line still fills all of it.
    private static func textRange(in rect: NSRect, layoutManager: TextLayoutManager) -> NSRange? {
        guard let first = layoutManager.textLineForPosition(max(rect.minY, 0)),
              let last = layoutManager.textLineForPosition(max(rect.maxY, 0)) else {
            return nil
        }
        return NSRange(start: first.range.location, end: max(first.range.max, last.range.max))
    }

    /// Find fill rects for a specific line position and append them to `fillRects`.
    ///
    /// Appended rects are unclipped - end-of-line rects extend to `CGFloat.greatestFiniteMagnitude` and are clipped
    /// to the drawing rect by the caller.
    /// - Parameters:
    ///   - fillRects: Output buffer.
    ///   - selStart: Selection start (location).
    ///   - selEnd: Selection end (location + length).
    ///   - linePosition: The line position to use.
    ///   - layoutManager: The layout manager.
    private func appendFillRects(
        into fillRects: inout ContiguousArray<CGRect>,
        selStart: Int,
        selEnd: Int,
        forPosition linePosition: TextLineStorage<TextLine>.TextLinePosition,
        layoutManager: TextLayoutManager
    ) {
        let lineLocation = linePosition.range.location
        let lineLength = linePosition.range.length

        // The selected range contains some portion of the line
        for fragmentPosition in linePosition.data.lineFragments {
            // Inline shifted range as scalars - avoids the `range.shifted(by:)` allocation per fragment.
            let fragStart = fragmentPosition.range.location + lineLocation
            let fragEnd = fragStart + fragmentPosition.range.length

            // Intersect (selStart, selEnd) with (fragStart, fragEnd).
            let interStart = max(selStart, fragStart)
            let interEnd = min(selEnd, fragEnd)
            guard interStart < interEnd, let minRect = layoutManager.rectForOffset(interStart) else {
                continue
            }

            let maxRect: CGRect
            // Original: `fragmentRange.max <= range.max || range.contains(fragmentRange.max)`.
            // `range.contains(fragEnd)` ≡ `selStart <= fragEnd && fragEnd < selEnd`.
            let endOfLine = fragEnd <= selEnd || (selStart <= fragEnd && fragEnd < selEnd)
            let endOfDocument = interEnd == layoutManager.lineStorage.length
            let emptyLine = lineLength == 0

            if endOfLine && !(endOfDocument && !emptyLine) {
                maxRect = CGRect(
                    x: CGFloat.greatestFiniteMagnitude,
                    y: fragmentPosition.yPos + linePosition.yPos,
                    width: 0,
                    height: fragmentPosition.height
                )
            } else if let maxFragmentRect = layoutManager.rectForOffset(interEnd) {
                maxRect = maxFragmentRect
            } else {
                continue
            }

            fillRects.append(CGRect(
                x: minRect.origin.x,
                y: minRect.origin.y,
                width: maxRect.minX - minRect.minX,
                height: max(minRect.height, maxRect.height)
            ))
        }
    }
}
