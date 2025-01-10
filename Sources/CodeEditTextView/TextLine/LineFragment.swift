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
    public let id = UUID()
    private(set) public var ctLine: CTLine
    public let width: CGFloat
    public let height: CGFloat
    public let descent: CGFloat
    public let scaledHeight: CGFloat

    /// The difference between the real text height and the scaled height
    public var heightDifference: CGFloat {
        scaledHeight - height
    }

    init(
        ctLine: CTLine,
        width: CGFloat,
        height: CGFloat,
        descent: CGFloat,
        lineHeightMultiplier: CGFloat
    ) {
        self.ctLine = ctLine
        self.width = width
        self.height = height
        self.descent = descent
        self.scaledHeight = height * lineHeightMultiplier
    }

    public static func == (lhs: LineFragment, rhs: LineFragment) -> Bool {
        lhs.id == rhs.id
    }

    /// Finds the x position of the offset in the string the fragment represents.
    /// - Parameter offset: The offset, relative to the start of the *line*.
    /// - Returns: The x position of the character in the drawn line, from the left.
    public func xPos(for offset: Int) -> CGFloat {
        let lineRange = CTLineGetStringRange(ctLine)
        return CTLineGetOffsetForStringIndex(ctLine, offset, nil)
    }

    public func draw(in context: CGContext, yPos: CGFloat) {
        context.saveGState()

        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setAllowsFontSmoothing(false)
        context.setShouldSmoothFonts(false)
        context.setAllowsFontSubpixelPositioning(true)
        context.setShouldSubpixelPositionFonts(true)
        context.setAllowsFontSubpixelQuantization(true)
        context.setShouldSubpixelQuantizeFonts(true)

        ContextSetHiddenSmoothingStyle(context, 16)

        context.textMatrix = .init(scaleX: 1, y: -1)
        context.textPosition = CGPoint(
            x: 0,
            y: yPos + (height - descent + (heightDifference/2))
        ).pixelAligned

        CTLineDraw(ctLine, context)
        context.restoreGState()
    }
}
