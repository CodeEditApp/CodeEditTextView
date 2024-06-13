//
//  TextView+ReplaceCharacters.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 9/3/23.
//

import AppKit
import TextStory

extension TextView {
    /// Replace the characters in the given ranges with the given string.
    /// - Parameters:
    ///   - ranges: The ranges to replace
    ///   - string: The string to insert in the ranges.
    public func replaceCharacters(in ranges: [NSRange], with string: String) {
        guard isEditable else { return }
        NotificationCenter.default.post(name: Self.textWillChangeNotification, object: self)
        layoutManager.beginTransaction()
        textStorage.beginEditing()

        // Can't insert an empty string into an empty range. One must be not empty
        for range in ranges.sorted(by: { $0.location > $1.location }) where
        (!range.isEmpty || !string.isEmpty) &&
        (delegate?.textView(self, shouldReplaceContentsIn: range, with: string) ?? true) {
            delegate?.textView(self, willReplaceContentsIn: range, with: string)

            layoutManager.willReplaceCharactersInRange(range: range, with: string)
            _undoManager?.registerMutation(
                TextMutation(string: string as String, range: range, limit: textStorage.length)
            )
            textStorage.replaceCharacters(
                in: range,
                with: NSAttributedString(string: string, attributes: typingAttributes)
            )
            selectionManager.didReplaceCharacters(in: range, replacementLength: (string as NSString).length)

            delegate?.textView(self, didReplaceContentsIn: range, with: string)
        }

        layoutManager.endTransaction()
        textStorage.endEditing()
        selectionManager.notifyAfterEdit()
        NotificationCenter.default.post(name: Self.textDidChangeNotification, object: self)
    }

    /// Replace the characters in a range with a new string.
    /// - Parameters:
    ///   - range: The range to replace.
    ///   - string: The string to insert in the range.
    public func replaceCharacters(in range: NSRange, with string: String) {
        replaceCharacters(in: [range], with: string)
    }
}
