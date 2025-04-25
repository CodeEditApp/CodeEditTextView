//
//  TypesetContext.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 4/24/25.
//

import Foundation

struct TypesetContext {
    let documentRange: NSRange
    let displayData: TextLine.DisplayData

    var lines: [TextLineStorage<LineFragment>.BuildItem] = []
    var maxHeight: CGFloat = 0
    var fragmentContext: LineFragmentTypesetContext = .init(start: 0, width: 0.0, height: 0.0, descent: 0.0)
    var currentPosition: Int = 0

    mutating func appendAttachment(_ attachment: TextAttachmentBox) {
        // Check if we can append this attachment to the current line
        if fragmentContext.width + attachment.width > displayData.maxWidth {
            popCurrentData()
        }

        // Add the attachment to the current line
        fragmentContext.contents.append(
            .init(data: .attachment(attachment: attachment), width: attachment.width)
        )
        fragmentContext.width += attachment.width
        fragmentContext.height = fragmentContext.height == 0 ? maxHeight : fragmentContext.height
        currentPosition += attachment.range.length
    }

    mutating func appendText(lineBreak: Int, typesetData: CTLineTypesetData) {
        fragmentContext.contents.append(
            .init(data: .text(line: typesetData.ctLine), width: typesetData.width)
        )
        fragmentContext.width += typesetData.width
        fragmentContext.height = typesetData.height
        fragmentContext.descent = max(typesetData.descent, fragmentContext.descent)
        currentPosition += lineBreak
    }

    mutating func popCurrentData() {
        let fragment = LineFragment(
            documentRange: NSRange(
                location: fragmentContext.start + documentRange.location,
                length: currentPosition - fragmentContext.start
            ),
            contents: fragmentContext.contents,
            width: fragmentContext.width,
            height: fragmentContext.height,
            descent: fragmentContext.descent,
            lineHeightMultiplier: displayData.lineHeightMultiplier
        )
        lines.append(
            .init(data: fragment, length: currentPosition - fragmentContext.start, height: fragment.scaledHeight)
        )
        maxHeight = max(maxHeight, fragment.scaledHeight)

        fragmentContext.clear()
        fragmentContext.start = currentPosition
    }
}
