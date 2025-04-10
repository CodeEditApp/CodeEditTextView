//
//  TextLayoutManagerLayoutDelegate.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 4/10/25.
//

import AppKit

/// Provide an instance of this class to the ``TextLayoutManager`` to override how the layout manager performs layout
/// and display for text lines and fragments.
///
/// All methods on this protocol are optional, and default to the default behavior.
public protocol TextLayoutManagerRenderDelegate: AnyObject {
    func prepareForDisplay( // swiftlint:disable:this function_parameter_count
        textLine: TextLine,
        displayData: TextLine.DisplayData,
        range: NSRange,
        stringRef: NSTextStorage,
        markedRanges: MarkedRanges?,
        breakStrategy: LineBreakStrategy
    )
    func drawLineFragment(fragment: LineFragment, in context: CGContext)
}

extension TextLayoutManagerRenderDelegate {
    func prepareForDisplay( // swiftlint:disable:this function_parameter_count
        textLine: TextLine,
        displayData: TextLine.DisplayData,
        range: NSRange,
        stringRef: NSTextStorage,
        markedRanges: MarkedRanges?,
        breakStrategy: LineBreakStrategy
    ) {
        textLine.prepareForDisplay(
            displayData: displayData,
            range: range,
            stringRef: stringRef,
            markedRanges: markedRanges,
            breakStrategy: breakStrategy
        )
    }

    func drawLineFragment(fragment: LineFragment, in context: CGContext) {
        fragment.draw(in: context, yPos: 0.0)
    }
}
