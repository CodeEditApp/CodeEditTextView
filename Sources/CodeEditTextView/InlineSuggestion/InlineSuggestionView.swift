//
//  InlineSuggestionView.swift
//  CodeEditTextView
//
//  Created by anxkhn on 6/29/26.
//

import AppKit
import CodeEditTextViewObjC

/// Draws inline "ghost text" as a sibling overlay of a ``TextView``.
///
/// This view holds pre-typeset `CTLine`s and the geometry needed to position them. It draws them in a dimmed color
/// using the same Core Text drawing context setup as ``LineFragmentRenderer``, so the ghost text visually matches the
/// real text. The view never mutates text storage and ignores hit testing so it does not interfere with selection or
/// editing.
open class InlineSuggestionView: NSView {
    /// The geometry needed to position the suggestion's typeset lines.
    struct Geometry {
        /// The x position of the first line, anchored to the caret.
        let firstLineXPosition: CGFloat
        /// The x position of wrapped or subsequent lines, anchored to the text view's leading edge inset.
        let continuationXPosition: CGFloat
        /// The height of each line.
        let lineHeight: CGFloat
        /// The descent of the typeset lines.
        let descent: CGFloat
        /// The difference between the scaled and unscaled line height.
        let heightDifference: CGFloat
    }

    /// The pre-typeset lines to draw. Line `0` is drawn at the caret, lines `1...` at the continuation x position.
    private(set) var ctLines: [CTLine]
    private var geometry: Geometry

    override open var isFlipped: Bool {
        true
    }

    override open var isOpaque: Bool {
        false
    }

    override open func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Create an inline suggestion view.
    /// - Parameters:
    ///   - ctLines: The pre-typeset lines to draw.
    ///   - geometry: The geometry used to position the lines.
    init(ctLines: [CTLine], geometry: Geometry) {
        self.ctLines = ctLines
        self.geometry = geometry
        super.init(frame: .zero)
        wantsLayer = true
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Update the typeset lines and geometry, then request a redraw.
    /// - Parameters:
    ///   - ctLines: The new pre-typeset lines to draw.
    ///   - geometry: The new geometry used to position the lines.
    func update(ctLines: [CTLine], geometry: Geometry) {
        self.ctLines = ctLines
        self.geometry = geometry
        needsDisplay = true
    }

    /// Update the geometry without re-typesetting the lines, then request a redraw.
    /// - Parameter geometry: The new geometry used to position the lines.
    func update(geometry: Geometry) {
        self.geometry = geometry
        needsDisplay = true
    }

    /// The x position to draw the line at the given index.
    private func xFor(_ index: Int) -> CGFloat {
        index == 0 ? geometry.firstLineXPosition : geometry.continuationXPosition
    }

    override open func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

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

        for (index, ctLine) in ctLines.enumerated() {
            context.textPosition = CGPoint(
                x: xFor(index),
                y: CGFloat(index) * geometry.lineHeight
                    + geometry.lineHeight - geometry.descent + (geometry.heightDifference / 2)
            ).pixelAligned
            CTLineDraw(ctLine, context)
        }

        context.restoreGState()
    }
}
