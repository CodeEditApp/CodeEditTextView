//
//  TextLayoutManager+Decorations.swift
//  CodeEditTextView
//
//  Created by Abe Malla on 4/12/26.
//

import AppKit

extension TextLayoutManager {
    /// Draws line decoration backgrounds for lines visible in the given dirty rect.
    ///
    /// Called during the view's `draw(_:)` pass, before text and selections are drawn, so that
    /// line backgrounds appear as an underlay.
    ///
    /// - Parameter dirtyRect: The rect being drawn, in the text view's coordinate space.
    public func drawLineDecorations(in dirtyRect: NSRect) {
        guard lineDecorations.count > 0 else { return }
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Determine the visible line range from the dirty rect.
        let minY = max(dirtyRect.minY, 0)
        let maxY = dirtyRect.maxY

        guard let firstLine = textLineForPosition(minY),
              let lastLine = textLineForPosition(maxY) else {
            return
        }

        let visibleLineRange = firstLine.index...lastLine.index
        let decorations = lineDecorations.decorations(inLineRange: visibleLineRange)
        guard !decorations.isEmpty else { return }

        let viewportWidth = delegate?.textViewportSize().width ?? layoutView?.bounds.width ?? 0
        let hasViewZones = !viewZones.zones.isEmpty
        let padding = LineHighlightDrawing.horizontalPadding

        for decoration in decorations {
            // Clamp the decoration range to visible lines.
            let clampedLower = max(decoration.lineRange.lowerBound, visibleLineRange.lowerBound)
            let clampedUpper = min(decoration.lineRange.upperBound, visibleLineRange.upperBound)

            // Build a single rect spanning all lines in this decoration range
            guard let firstLinePos = lineStorage.getLine(atIndex: clampedLower),
                  let lastLinePos = lineStorage.getLine(atIndex: clampedUpper) else {
                continue
            }

            let firstWhitespace = hasViewZones
                ? viewZones.whitespaceHeightBeforeLine(clampedLower) : 0.0
            let lastWhitespace = hasViewZones
                ? viewZones.whitespaceHeightBeforeLine(clampedUpper) : 0.0

            let spanY = firstLinePos.yPos + firstWhitespace
            let spanMaxY = lastLinePos.yPos + lastWhitespace + lastLinePos.height
            let spanRect = CGRect(
                x: edgeInsets.left + padding,
                y: spanY,
                width: viewportWidth - edgeInsets.left - edgeInsets.right - 2 * padding,
                height: spanMaxY - spanY
            )

            switch decoration.style {
            case .lineBackground(let color):
                LineHighlightDrawing.fillRoundedRect(
                    spanRect, color: color.cgColor, in: context
                )

            case .custom(let drawFunc):
                for lineIndex in clampedLower...clampedUpper {
                    guard let linePosition = lineStorage.getLine(atIndex: lineIndex) else { continue }
                    let whitespaceOffset = hasViewZones
                        ? viewZones.whitespaceHeightBeforeLine(lineIndex) : 0.0
                    let lineY = linePosition.yPos + whitespaceOffset
                    let lineRect = CGRect(
                        x: 0,
                        y: lineY,
                        width: viewportWidth,
                        height: linePosition.height
                    )
                    context.saveGState()
                    drawFunc(context, lineRect, lineIndex)
                    context.restoreGState()
                }

            case .overviewRuler:
                // Drawn by the minimap/scrollbar, not in the main text view draw pass.
                break
            }
        }
    }
}
