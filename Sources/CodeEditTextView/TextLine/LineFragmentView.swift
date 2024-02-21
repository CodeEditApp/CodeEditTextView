//
//  LineFragmentView.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 8/14/23.
//

import AppKit
import CodeEditTextViewObjC

/// Displays a line fragment.
final class LineFragmentView: NSView {
    private weak var lineFragment: LineFragment?

    override var isFlipped: Bool {
        true
    }

    override var isOpaque: Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Prepare the view for reuse, clears the line fragment reference.
    override func prepareForReuse() {
        super.prepareForReuse()
        lineFragment = nil
    }

    /// Set a new line fragment for this view, updating view size.
    /// - Parameter newFragment: The new fragment to use.
    public func setLineFragment(_ newFragment: LineFragment) {
        self.lineFragment = newFragment
        self.frame.size = CGSize(width: newFragment.width, height: newFragment.scaledHeight)
    }

    /// Draws the line fragment in the graphics context.
    override func draw(_ dirtyRect: NSRect) {
        guard let lineFragment, let context = NSGraphicsContext.current?.cgContext else {
            return
        }
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
            y: lineFragment.height - lineFragment.descent + (lineFragment.heightDifference/2)
        ).pixelAligned

        CTLineDraw(lineFragment.ctLine, context)
        context.restoreGState()
    }
}
