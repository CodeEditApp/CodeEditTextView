//
//  TextView+InlineSuggestion.swift
//  CodeEditTextView
//
//  Created by anxkhn on 6/29/26.
//

import Foundation

extension TextView {
    /// Displays an inline "ghost text" suggestion anchored at the given document offset.
    ///
    /// Passing `nil` or an empty string clears any existing suggestion. The suggestion is rendered as an overlay and
    /// never mutates ``TextView/textStorage`` or shifts real text layout.
    /// - Parameters:
    ///   - text: The suggestion text. May contain line breaks for a multi-line suggestion.
    ///   - offset: The document offset to anchor the suggestion to.
    public func setInlineSuggestion(_ text: String?, at offset: Int) {
        inlineSuggestionManager?.setSuggestion(text, at: offset)
    }

    /// Displays an inline "ghost text" suggestion anchored at the primary caret.
    ///
    /// Passing `nil` or an empty string clears any existing suggestion.
    /// - Parameter text: The suggestion text. May contain line breaks for a multi-line suggestion.
    public func setInlineSuggestion(_ text: String?) {
        let offset = selectionManager.textSelections.first?.range.location ?? 0
        inlineSuggestionManager?.setSuggestion(text, at: offset)
    }

    /// Clears any displayed inline suggestion.
    public func clearInlineSuggestion() {
        inlineSuggestionManager?.clearSuggestion()
    }
}
