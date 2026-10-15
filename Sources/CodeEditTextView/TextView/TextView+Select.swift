//
//  TextView+Select.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 10/20/23.
//

import AppKit

extension TextView {
    override public func selectAll(_ sender: Any?) {
        selectionManager.setSelectedRange(documentRange)
        unmarkTextIfNeeded()
        needsDisplay = true
    }

    override public func selectLine(_ sender: Any?) {
        let newSelections = selectionManager.textSelections.compactMap { textSelection -> NSRange? in
            guard let linePosition = layoutManager.textLineForOffset(textSelection.range.location) else {
                return nil
            }
            return linePosition.range
        }
        selectionManager.setSelectedRanges(newSelections)
        unmarkTextIfNeeded()
        needsDisplay = true
    }

    override public func selectWord(_ sender: Any?) {
        let newSelections = selectionManager.textSelections.compactMap { (textSelection) -> NSRange? in
                guard textSelection.range.isEmpty else {
                    return nil
                }
                return findWordBoundary(at: textSelection.range.location)
            }
        selectionManager.setSelectedRanges(newSelections)
        unmarkTextIfNeeded()
        needsDisplay = true
    }

    /// Given a position, find the range of the word that exists at that position.
    ///
    /// `position` is a caret index from hit-testing, so a click past a glyph's midpoint yields the index of the
    /// *following* character. A boundary index directly after an identifier run therefore selects the preceding
    /// word, matching the system text view's double-click behavior.
    internal func findWordBoundary(at position: Int) -> NSRange {
        let string = textStorage.string as NSString
        guard string.length > 0, position >= 0, position <= string.length else {
            return NSRange(location: position, length: 0)
        }

        var charRange = string.rangeOfComposedCharacterSequence(at: min(position, string.length - 1))
        var characterSet = characterClass(of: charRange, in: string)

        // Only fall back to the preceding word when the clicked sequence is a true boundary class (whitespace,
        // newline, punctuation). Unclassified sequences (emoji, symbols) are selectable content themselves -
        // re-classifying them would make an emoji following an identifier run unselectable from its left half.
        if characterSet != nil, characterSet != .codeIdentifierCharacters, position > 0 {
            let precedingRange = string.rangeOfComposedCharacterSequence(at: position - 1)
            if characterClass(of: precedingRange, in: string) == .codeIdentifierCharacters {
                charRange = precedingRange
                characterSet = .codeIdentifierCharacters
            }
        }

        guard let characterSet else {
            // Unclassified content (symbols, emoji) selects the composed character sequence itself.
            return charRange
        }

        let invertedSet = characterSet.inverted
        let followingBreak = string.rangeOfCharacter(
            from: invertedSet,
            options: [],
            range: NSRange(location: charRange.upperBound, length: string.length - charRange.upperBound)
        )
        let end = followingBreak.location == NSNotFound ? string.length : followingBreak.location

        let precedingBreak = string.rangeOfCharacter(
            from: invertedSet,
            options: .backwards,
            range: NSRange(location: 0, length: charRange.location)
        )
        let start = precedingBreak.location == NSNotFound ? 0 : precedingBreak.upperBound

        return NSRange(start: start, end: end)
    }

    /// Classifies a composed character sequence into the character set that determines its word-run membership.
    private func characterClass(of range: NSRange, in string: NSString) -> CharacterSet? {
        let charSet = CharacterSet(charactersIn: string.substring(with: range))
        if CharacterSet.codeIdentifierCharacters.isSuperset(of: charSet) {
            return .codeIdentifierCharacters
        } else if CharacterSet.whitespaces.isSuperset(of: charSet) {
            return .whitespaces
        } else if CharacterSet.newlines.isSuperset(of: charSet) {
            return .newlines
        } else if CharacterSet.punctuationCharacters.isSuperset(of: charSet) {
            return .punctuationCharacters
        }
        return nil
    }

    /// Given a position, find the range of the entire line that exists at that position.
    internal func findLineBoundary(at position: Int) -> NSRange {
        guard let linePosition = layoutManager.textLineForOffset(position) else {
            return NSRange(location: position, length: 0)
        }
        return linePosition.range
    }
}
