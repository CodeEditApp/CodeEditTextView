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
    /// What a decoration draws depends only on its lines and the view's width, never on `dirtyRect`: a partial
    /// redraw has to reproduce exactly the pixels of a full one. A background is filled as one rounded span over all
    /// of its lines and left to the clip, since a span cut at the edges of the rect would round its corners there.
    ///
    /// - Parameter dirtyRect: The rect being drawn, in the text view's coordinate space.
    public func drawLineDecorations(in dirtyRect: NSRect) {
        guard lineDecorations.count > 0 else { return }
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // The lines the dirty rect touches, by index: from the first visible line through every line folded into the
        // last one, and one more - lines without height (folded away, or ending where a view zone's whitespace
        // begins) can sit exactly on the rect's edge, and a decoration starting on one still paints inside it.
        let minY = max(dirtyRect.minY, 0)
        let maxY = dirtyRect.maxY
        guard let firstLine = visibleLineIndices(atDocumentY: minY),
              let lastLine = visibleLineIndices(atDocumentY: maxY),
              firstLine.lowerBound <= lastLine.upperBound else {
            return
        }
        let visibleLineRange = firstLine.lowerBound...min(lastLine.upperBound + 1, lineStorage.count - 1)
        let decorations = lineDecorations.decorations(inLineRange: visibleLineRange)
        guard !decorations.isEmpty else { return }

        let width = layoutView?.bounds.width ?? delegate?.textViewportSize().width ?? 0
        let padding = LineHighlightDrawing.horizontalPadding
        let lastLineIndex = lineStorage.count - 1

        for decoration in decorations {
            switch decoration.style {
            case .lineBackground(let color):
                let lower = max(decoration.lineRange.lowerBound, 0)
                let upper = min(decoration.lineRange.upperBound, lastLineIndex)
                guard lower <= upper,
                      let spanY = documentY(ofLine: lower),
                      let lastLinePos = lineStorage.getLine(atIndex: upper),
                      let lastY = documentY(ofLine: upper) else {
                    continue
                }
                let spanRect = CGRect(
                    x: edgeInsets.left + padding,
                    y: spanY,
                    width: width - edgeInsets.left - edgeInsets.right - 2 * padding,
                    height: lastY + lastLinePos.height - spanY
                )
                LineHighlightDrawing.fillRoundedRect(
                    context.deviceAligned(spanRect),
                    color: color.cgColor,
                    in: context
                )

            case .custom(let drawFunc):
                // Drawn line by line, so only the lines this rect overlaps are needed.
                let lower = max(decoration.lineRange.lowerBound, visibleLineRange.lowerBound)
                let upper = min(decoration.lineRange.upperBound, visibleLineRange.upperBound)
                guard lower <= upper else { continue }
                for lineIndex in lower...upper {
                    guard let linePosition = lineStorage.getLine(atIndex: lineIndex),
                          let lineY = documentY(ofLine: lineIndex) else {
                        continue
                    }
                    let lineRect = CGRect(x: 0, y: lineY, width: width, height: linePosition.height)
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

    /// The indices of the visible line at `documentY`: one line, or every line an attachment folds into it.
    private func visibleLineIndices(atDocumentY documentY: CGFloat) -> ClosedRange<Int>? {
        determineVisiblePosition(for: lineStorage.getLine(atPosition: documentYToLineStorageY(documentY)))?.indexRange
    }

    /// The document y of the line at `index`: its line storage y plus the view zone whitespace above it.
    private func documentY(ofLine index: Int) -> CGFloat? {
        guard let position = lineStorage.getLine(atIndex: index) else { return nil }
        return viewZones.zones.isEmpty ? position.yPos : lineStorageYToDocumentY(position.yPos, lineIndex: index)
    }
}
