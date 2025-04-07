//
//  LineFragment.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 6/29/23.
//

import AppKit

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

    /// Calculates the drawing rect for a given range.
    /// - Parameter range: The range to calculate the bounds for, relative to the line.
    /// - Returns: A rect that contains the text contents in the given range.
    func rectFor(range: NSRange) -> CGRect {
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
