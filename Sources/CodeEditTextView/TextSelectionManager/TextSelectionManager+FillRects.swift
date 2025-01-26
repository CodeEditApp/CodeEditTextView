//
//  TextSelectionManager+FillRects.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 10/22/23.
//

import Foundation

extension TextSelectionManager {
    /// Calculate a set of rects for a text selection suitable for filling with the selection color to indicate a
    /// multi-line selection.
    ///
    /// The returned rects are inset by edge insets passed to the text view, the given `rect` parameter can be the 'raw'
    /// rect to draw in, no need to inset it before this method call.
    ///
    /// - Parameters:
    ///   - rect: The bounding rect of available draw space.
    ///   - textSelection: The selection to use.
    /// - Returns: An array of rects that the selection overlaps.
    func getFillRects(in rect: NSRect, for textSelection: TextSelection) -> [CGRect] {
        guard let layoutManager else { return [] }
        let range = textSelection.range

        var fillRects: [CGRect] = []

        let insetXPos = max(layoutManager.edgeInsets.left, rect.minX)
        let insetWidth = max(0, rect.maxX - insetXPos - layoutManager.edgeInsets.right)
        let insetRect = NSRect(x: insetXPos, y: rect.origin.y, width: insetWidth, height: rect.height)

        for linePosition in layoutManager.lineStorage.linesInRange(range) {
            fillRects.append(contentsOf: getFillRects(in: insetRect, selectionRange: range, forPosition: linePosition))
        }

        // Pixel align these to avoid aliasing on the edges of each rect that should be a solid box.
        return fillRects.map { $0.intersection(insetRect).pixelAligned }
    }

    /// Find fill rects for a specific line position.
    /// - Parameters:
    ///   - rect: The bounding rect of the overall view.
    ///   - range: The selected range to create fill rects for.
    ///   - linePosition: The line position to use.
    /// - Returns: An array of rects that the selection overlaps.
    private func getFillRects(
        in rect: NSRect,
        selectionRange range: NSRange,
        forPosition linePosition: TextLineStorage<TextLine>.TextLinePosition
    ) -> [CGRect] {
        guard let layoutManager else { return [] }
        var fillRects: [CGRect] = []

        // The selected range contains some portion of the line
        for fragmentPosition in linePosition.data.lineFragments {
            guard let fragmentRange = fragmentPosition
                .range
                .shifted(by: linePosition.range.location),
                  let intersectionRange = fragmentRange.intersection(range),
                  let minRect = layoutManager.rectForOffset(intersectionRange.location) else {
                continue
            }

            let maxRect: CGRect
            // If the selection is at the end of the line, or contains the end of the fragment, and is not the end
            // of the document, we select the entire line to the right of the selection point.
            if (fragmentRange.max <= range.max || range.contains(fragmentRange.max))
                && intersectionRange.max != layoutManager.lineStorage.length {
                maxRect = CGRect(
                    x: rect.maxX,
                    y: fragmentPosition.yPos + linePosition.yPos,
                    width: 0,
                    height: fragmentPosition.height
                )
            } else if let maxFragmentRect = layoutManager.rectForOffset(intersectionRange.max) {
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

        return fillRects
    }
}
