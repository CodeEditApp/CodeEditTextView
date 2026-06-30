//
//  InlineSuggestion.swift
//  CodeEditTextView
//
//  Created by anxkhn on 6/29/26.
//

import Foundation

/// Represents an inline "ghost text" suggestion to display in a text view.
///
/// A suggestion is purely a rendering hint. It is drawn as a sibling overlay anchored at the caret and never mutates
/// the text view's ``TextView/textStorage`` or shifts real text layout. This makes it suitable as the foundation for
/// inline completions, such as those provided by GitHub Copilot.
public struct InlineSuggestion: Equatable {
    /// The document offset the suggestion is anchored to. This is typically the primary caret position.
    public let offset: Int

    /// The text to display. May contain line breaks to render a multi-line suggestion.
    public let text: String

    /// Create an inline suggestion.
    /// - Parameters:
    ///   - offset: The document offset to anchor the suggestion to.
    ///   - text: The text to display. May contain line breaks for a multi-line suggestion.
    public init(offset: Int, text: String) {
        self.offset = offset
        self.text = text
    }
}
