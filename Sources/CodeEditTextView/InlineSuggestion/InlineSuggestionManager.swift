//
//  InlineSuggestionManager.swift
//  CodeEditTextView
//
//  Created by anxkhn on 6/29/26.
//

import AppKit

/// Manages a single inline "ghost text" suggestion within a ``TextView``.
///
/// The suggestion is rendered by an ``InlineSuggestionView`` inserted as a sibling overlay below the text view's
/// content. The manager never mutates ``TextView/textStorage`` and never shifts real text layout. It only typesets the
/// suggestion text and positions the overlay at the caret using ``TextLayoutManager/rectForOffset(_:)``.
public final class InlineSuggestionManager {
    weak var textView: TextView?

    /// The color used to draw the ghost text. Defaults to ``NSColor/placeholderTextColor``.
    public var suggestionColor: NSColor = .placeholderTextColor

    /// The suggestion currently being displayed, if any.
    public private(set) var current: InlineSuggestion?

    /// The overlay view drawing the current suggestion, if any.
    private var suggestionView: InlineSuggestionView?

    init(textView: TextView) {
        self.textView = textView
    }

    // MARK: - Set, Clear

    /// Sets the suggestion text anchored at the given document offset.
    ///
    /// Passing `nil` or an empty string clears any existing suggestion.
    /// - Parameters:
    ///   - text: The suggestion text. May contain line breaks for a multi-line suggestion.
    ///   - offset: The document offset to anchor the suggestion to.
    public func setSuggestion(_ text: String?, at offset: Int) {
        guard let text, !text.isEmpty else {
            clearSuggestion()
            return
        }
        setSuggestion(InlineSuggestion(offset: offset, text: text))
    }

    /// Sets the suggestion to display.
    ///
    /// Passing `nil` clears any existing suggestion.
    /// - Parameter suggestion: The suggestion to display, or `nil` to clear.
    public func setSuggestion(_ suggestion: InlineSuggestion?) {
        guard let suggestion else {
            clearSuggestion()
            return
        }
        current = suggestion
        render(suggestion, rebuildLines: true)
    }

    /// Clears any displayed suggestion and removes the overlay view.
    public func clearSuggestion() {
        current = nil
        suggestionView?.removeFromSuperview()
        suggestionView = nil
    }

    // MARK: - Layout

    /// Recomputes the suggestion's geometry and repositions the overlay.
    ///
    /// This is a cheap no-op when no suggestion is being displayed. If the anchored offset no longer fits within the
    /// document (for instance after an edit shrinks the text), the suggestion is cleared safely.
    public func updateLayout() {
        guard let current else { return }
        guard let textView, current.offset <= textView.textStorage.length else {
            clearSuggestion()
            return
        }
        render(current, rebuildLines: false)
    }

    // MARK: - Rendering

    /// Renders the given suggestion, inserting or updating the overlay view.
    /// - Parameters:
    ///   - suggestion: The suggestion to render.
    ///   - rebuildLines: Whether the typeset lines should be rebuilt. Pass `false` to only reposition.
    private func render(_ suggestion: InlineSuggestion, rebuildLines: Bool) {
        guard let textView else { return }

        let ctLines = rebuildLines || suggestionView == nil
            ? makeCTLines(for: suggestion.text)
            : suggestionView?.ctLines ?? makeCTLines(for: suggestion.text)

        guard let layout = makeLayout(for: suggestion, lineCount: ctLines.count) else {
            clearSuggestion()
            return
        }

        if let suggestionView {
            suggestionView.frame = layout.frame
            if rebuildLines {
                suggestionView.update(ctLines: ctLines, geometry: layout.geometry)
            } else {
                suggestionView.update(geometry: layout.geometry)
            }
        } else {
            let view = InlineSuggestionView(ctLines: ctLines, geometry: layout.geometry)
            view.frame = layout.frame
            textView.addSubview(view, positioned: .below, relativeTo: nil)
            suggestionView = view
        }
    }

    /// The drawing attributes for the ghost text, read from the text view's typing attributes.
    private func suggestionAttributes() -> [NSAttributedString.Key: Any] {
        guard let textView else { return [:] }
        return [
            .font: textView.font,
            .foregroundColor: suggestionColor,
            .kern: textView.kern
        ]
    }

    /// Typesets the suggestion text into one `CTLine` per line break.
    private func makeCTLines(for text: String) -> [CTLine] {
        let attributes = suggestionAttributes()
        return splitIntoLines(text).map { line in
            CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes))
        }
    }

    /// Splits the text into lines on any ``LineEnding`` sequence, preserving empty trailing lines.
    private func splitIntoLines(_ text: String) -> [String] {
        let endings = LineEnding.allCases.sorted { $0.length > $1.length }
        var lines: [String] = []
        var currentLine = ""
        var index = text.startIndex
        while index < text.endIndex {
            let remaining = text[index...]
            if let ending = endings.first(where: { remaining.hasPrefix($0.rawValue) }) {
                lines.append(currentLine)
                currentLine = ""
                index = text.index(index, offsetBy: ending.length)
            } else {
                currentLine.append(text[index])
                index = text.index(after: index)
            }
        }
        lines.append(currentLine)
        return lines
    }

    /// The computed frame and geometry for a suggestion.
    private struct Layout {
        let frame: CGRect
        let geometry: InlineSuggestionView.Geometry
    }

    /// Computes the overlay frame and drawing geometry for a suggestion.
    private func makeLayout(for suggestion: InlineSuggestion, lineCount: Int) -> Layout? {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let caretRect = layoutManager.rectForOffset(suggestion.offset) else {
            return nil
        }

        let lineHeight = layoutManager.estimateLineHeight()
        let (descent, heightDifference) = lineMetrics(multiplier: layoutManager.lineHeightMultiplier)

        let geometry = InlineSuggestionView.Geometry(
            firstLineXPosition: caretRect.minX,
            continuationXPosition: layoutManager.edgeInsets.left,
            lineHeight: lineHeight,
            descent: descent,
            heightDifference: heightDifference
        )

        let frame = CGRect(
            x: 0,
            y: caretRect.minY,
            width: textView.frame.width,
            height: lineHeight * CGFloat(lineCount)
        )

        return Layout(frame: frame, geometry: geometry)
    }

    /// Computes the descent and scaled height difference for the current suggestion attributes.
    private func lineMetrics(multiplier: CGFloat) -> (descent: CGFloat, heightDifference: CGFloat) {
        let referenceLine = CTLineCreateWithAttributedString(
            NSAttributedString(string: "0", attributes: suggestionAttributes())
        )
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        CTLineGetTypographicBounds(referenceLine, &ascent, &descent, &leading)
        let unscaledHeight = ascent + descent + leading
        let heightDifference = (unscaledHeight * multiplier) - unscaledHeight
        return (descent, heightDifference)
    }
}
