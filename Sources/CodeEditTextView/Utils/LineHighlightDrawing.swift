//
//  LineHighlightDrawing.swift
//  CodeEditTextView
//
//  Created by Abe Malla on 4/12/26.
//

import CoreGraphics

/// Shared configuration and drawing utilities for rounded line highlight backgrounds.
///
/// Used by both `TextSelectionManager` (current line highlight) and `TextLayoutManager` (line decoration
/// backgrounds) to ensure consistent appearance and a single place to tune padding/corner radius.
public enum LineHighlightDrawing {
    /// Horizontal inset from the edges of the drawing area.
    public static let horizontalPadding: CGFloat = 4.0

    /// Corner radius for the rounded rect.
    public static let cornerRadius: CGFloat = 4.0

    /// Fills a rounded-rect line background in the given context.
    ///
    /// - Parameters:
    ///   - rect: The rect to fill (should already account for padding).
    ///   - color: The fill color.
    ///   - context: The Core Graphics context to draw into.
    ///   - cornerRadius: Override for the corner radius. Defaults to ``cornerRadius``.
    public static func fillRoundedRect(
        _ rect: CGRect,
        color: CGColor,
        in context: CGContext,
        cornerRadius: CGFloat = Self.cornerRadius
    ) {
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        context.setFillColor(color)
        context.addPath(path)
        context.fillPath()
    }

    /// Fills a rect with only the leading (left) corners rounded. Used by the gutter view to match the
    /// text view's fully-rounded highlight on the trailing side.
    ///
    /// - Parameters:
    ///   - rect: The rect to fill.
    ///   - color: The fill color.
    ///   - context: The Core Graphics context to draw into.
    ///   - cornerRadius: Override for the corner radius. Defaults to ``cornerRadius``.
    public static func fillLeadingRoundedRect(
        _ rect: CGRect,
        color: CGColor,
        in context: CGContext,
        cornerRadius: CGFloat = Self.cornerRadius
    ) {
        let path = CGMutablePath()
        // Start at top-left rounded corner
        path.move(to: CGPoint(x: rect.minX + cornerRadius, y: rect.minY))
        // Top edge → straight right to trailing edge (no rounding)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        // Right edge → straight down
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        // Bottom edge → straight left to bottom-left corner
        path.addLine(to: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY))
        // Bottom-left rounded corner
        path.addArc(
            center: CGPoint(x: rect.minX + cornerRadius, y: rect.maxY - cornerRadius),
            radius: cornerRadius,
            startAngle: .pi / 2,
            endAngle: .pi,
            clockwise: false
        )
        // Left edge → straight up to top-left corner
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cornerRadius))
        // Top-left rounded corner
        path.addArc(
            center: CGPoint(x: rect.minX + cornerRadius, y: rect.minY + cornerRadius),
            radius: cornerRadius,
            startAngle: .pi,
            endAngle: 3 * .pi / 2,
            clockwise: false
        )
        path.closeSubpath()

        context.setFillColor(color)
        context.addPath(path)
        context.fillPath()
    }
}
