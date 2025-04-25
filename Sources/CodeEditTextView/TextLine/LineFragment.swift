//
//  LineFragment.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 6/29/23.
//

import AppKit
import CodeEditTextViewObjC

/// A ``LineFragment`` represents a subrange of characters in a line. Every text line contains at least one line
/// fragments, and any lines that need to be broken due to width constraints will contain more than one fragment.
public final class LineFragment: Identifiable, Equatable {
    public struct FragmentContent: Equatable {
        public enum Content: Equatable {
            case text(line: CTLine)
            case attachment(attachment: TextAttachmentBox)
        }

        let data: Content
        let width: CGFloat

        var length: Int {
            switch data {
            case .text(let line):
                CTLineGetStringRange(line).length
            case .attachment(let attachment):
                attachment.range.length
            }
        }

#if DEBUG
        var isText: Bool {
            switch data {
            case .text:
                true
            case .attachment:
                false
            }
        }
#endif
    }

    public struct ContentPosition {
        let xPos: CGFloat
        let offset: Int
    }

    public let id = UUID()
    public let documentRange: NSRange
    public var contents: [FragmentContent]
    public var width: CGFloat
    public var height: CGFloat
    public var descent: CGFloat
    public var scaledHeight: CGFloat

    /// The difference between the real text height and the scaled height
    public var heightDifference: CGFloat {
        scaledHeight - height
    }

    init(
        documentRange: NSRange,
        contents: [FragmentContent],
        width: CGFloat,
        height: CGFloat,
        descent: CGFloat,
        lineHeightMultiplier: CGFloat
    ) {
        self.documentRange = documentRange
        self.contents = contents
        self.width = width
        self.height = height
        self.descent = descent
        self.scaledHeight = height * lineHeightMultiplier
    }

    public static func == (lhs: LineFragment, rhs: LineFragment) -> Bool {
        lhs.id == rhs.id
    }

    /// Finds the x position of the offset in the string the fragment represents.
    ///
    /// Underscored, because although this needs to be accessible outside this class, the relevant layout manager method
    /// should be used.
    ///
    /// - Parameter offset: The offset, relative to the start of the *line*.
    /// - Returns: The x position of the character in the drawn line, from the left.
    func _xPos(for offset: Int) -> CGFloat {
        guard let (content, position) = findContent(at: offset) else {
            return width
        }
        switch content.data {
        case .text(let ctLine):
            return CTLineGetOffsetForStringIndex(ctLine, offset - position.offset, nil) + position.xPos
        case .attachment:
            return position.xPos
        }
    }

    public func draw(in context: CGContext, yPos: CGFloat) {
        context.saveGState()

        // Removes jagged edges
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        // Effectively increases the screen resolution by drawing text in each LED color pixel (R, G, or B), rather than
        // the triplet of pixels (RGB) for a regular pixel. This can increase text clarity, but loses effectiveness
        // in low-contrast settings.
        context.setAllowsFontSubpixelPositioning(true)
        context.setShouldSubpixelPositionFonts(true)

        // Quantizes the position of each glyph, resulting in slightly less accurate positioning, and gaining higher
        // quality bitmaps and performance.
        context.setAllowsFontSubpixelQuantization(true)
        context.setShouldSubpixelQuantizeFonts(true)

        ContextSetHiddenSmoothingStyle(context, 16)

        context.textMatrix = .init(scaleX: 1, y: -1)

        var currentPosition: CGFloat = 0.0
        var currentLocation = 0
        for content in contents {
            context.saveGState()
            switch content.data {
            case .text(let ctLine):
                context.textPosition = CGPoint(
                    x: currentPosition,
                    y: yPos + height - descent + (heightDifference/2)
                ).pixelAligned
                CTLineDraw(ctLine, context)
            case .attachment(let attachment):
                attachment.attachment.draw(
                    in: context,
                    rect: NSRect(x: currentPosition, y: yPos, width: attachment.width, height: scaledHeight)
                )
            }
            context.restoreGState()
            currentPosition += content.width
            currentLocation += content.length
        }
        context.restoreGState()
    }

    package func findContent(at location: Int) -> (content: FragmentContent, position: ContentPosition)? {
        var position = ContentPosition(xPos: 0, offset: 0)

        for content in contents {
            let length = content.length
            let width = content.width

            if (position.offset..<(position.offset + length)).contains(location) {
                return (content, position)
            }

            position = ContentPosition(xPos: position.xPos + width, offset: position.offset + length)
        }

        return nil
    }

    package func findContent(atX xPos: CGFloat) -> (content: FragmentContent, position: ContentPosition)? {
        var position = ContentPosition(xPos: 0, offset: 0)

        for content in contents {
            let length = content.length
            let width = content.width

            if (position.xPos..<(position.xPos + width)).contains(xPos) {
                return (content, position)
            }

            position = ContentPosition(xPos: position.xPos + width, offset: position.offset + length)
        }

        return nil
    }
}
