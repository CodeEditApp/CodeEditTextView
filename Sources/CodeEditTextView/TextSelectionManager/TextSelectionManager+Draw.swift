//
//  TextSelectionManager+Draw.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 1/12/25.
//

import AppKit

extension TextSelectionManager {
    /// Draws line backgrounds and selection rects for each selection in the given rect.
    /// - Parameter rect: The rect to draw in.
    public func drawSelections(in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        var highlightedLines: Set<TextLine.ID> = []
        // For each selection in the rect
        for textSelection in textSelections {
            if textSelection.range.isEmpty {
                drawHighlightedLine(
                    in: rect,
                    for: textSelection,
                    context: context,
                    highlightedLines: &highlightedLines
                )
            } else {
                drawSelectedRange(in: rect, for: textSelection, context: context)
            }
        }
        context.restoreGState()
    }

    /// Draws a highlighted line in the given rect.
    ///
    /// The highlight's geometry depends only on the line and the view's width, never on `rect`: a partial redraw
    /// must reproduce exactly the pixels a full one draws, or rounded corners appear at the edge of every rect that
    /// happened to be redrawn.
    /// - Parameters:
    ///   - rect: The rect to draw in.
    ///   - textSelection: The selection to draw.
    ///   - context: The context to draw in.
    ///   - highlightedLines: The set of all lines that have already been highlighted, used to avoid highlighting lines
    ///                       twice and updated if this function comes across a new line id.
    private func drawHighlightedLine(
        in rect: NSRect,
        for textSelection: TextSelection,
        context: CGContext,
        highlightedLines: inout Set<TextLine.ID>
    ) {
        guard let linePosition = layoutManager?.textLineForOffset(textSelection.range.location),
              !highlightedLines.contains(linePosition.data.id) else {
            return
        }
        highlightedLines.insert(linePosition.data.id)
        context.saveGState()

        let padding = LineHighlightDrawing.horizontalPadding
        let insetXPos = edgeInsets.left + padding
        let trailingInset = layoutManager?.edgeInsets.right ?? edgeInsets.right
        let width = (textView?.bounds.width ?? 0) - insetXPos - trailingInset - padding
        // Line storage y leaves out the view zones above the line; the highlight belongs at the line's document y.
        let documentY = layoutManager?.lineStorageYToDocumentY(linePosition.yPos, lineIndex: linePosition.index)
            ?? linePosition.yPos

        let selectionRect = CGRect(
            x: insetXPos,
            y: documentY,
            width: max(width, 0),
            height: linePosition.height
        ).pixelAligned

        if selectionRect.intersects(rect) {
            LineHighlightDrawing.fillRoundedRect(
                selectionRect,
                color: selectedLineBackgroundColor.cgColor,
                in: context
            )
        }
        context.restoreGState()
    }

    /// Draws a selected range in the given context.
    /// - Parameters:
    ///   - rect: The rect to draw in.
    ///   - range: The range to highlight.
    ///   - context: The context to draw in.
    private func drawSelectedRange(in rect: NSRect, for textSelection: TextSelection, context: CGContext) {
        context.saveGState()

        let fillColor = (textView?.isFirstResponder ?? false)
        ? selectionBackgroundColor.cgColor
        : selectionBackgroundColor.grayscale.cgColor

        context.setFillColor(fillColor)

        let fillRects = getFillRects(in: rect, for: textSelection)
        textSelection.boundingRect = fillRects.boundingRect()

        context.fill(fillRects)
        context.restoreGState()
    }

}
