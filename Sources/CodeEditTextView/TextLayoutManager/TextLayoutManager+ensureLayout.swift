//
//  TextLayoutManager+ensureLayout.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 4/7/25.
//

import Foundation

extension TextLayoutManager {
    /// Forces layout calculation for all lines up to and including the given offset.
    /// - Parameter offset: The offset to ensure layout until.
    package func ensureLayoutFor(position: TextLineStorage<TextLine>.TextLinePosition) -> CGFloat {
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
