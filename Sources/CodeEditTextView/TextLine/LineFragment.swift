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
    public var ctLine: CTLine
    public var width: CGFloat
    public var height: CGFloat
    public var descent: CGFloat
    public var scaledHeight: CGFloat

    /// The difference between the real text height and the scaled height
    public var heightDifference: CGFloat {
        scaledHeight - height
    }

    public init(
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
        return CTLineGetOffsetForStringIndex(ctLine, offset, nil)
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
        context.textPosition = CGPoint(
            x: 0,
            y: yPos + height - descent + (heightDifference/2)
        ).pixelAligned

        CTLineDraw(ctLine, context)
        context.restoreGState()
    }

    /// Calculates the drawing rect for a given range.
    /// - Parameter range: The range to calculate the bounds for, relative to the line.
    /// - Returns: A rect that contains the text contents in the given range.
    public func rectFor(range: NSRange) -> CGRect {
        let minXPos = CTLineGetOffsetForStringIndex(ctLine, range.lowerBound, nil)
        let maxXPos = CTLineGetOffsetForStringIndex(ctLine, range.upperBound, nil)
        return CGRect(
            x: minXPos,
            y: 0,
            width: maxXPos - minXPos,
            height: scaledHeight
        )
    }
}
