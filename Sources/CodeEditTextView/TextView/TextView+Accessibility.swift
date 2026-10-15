//
//  TextView+Accessibility.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 10/14/23.
//

import AppKit

/// # Notes
///
/// ~~This implementation considers the entire document as one element, ignoring all subviews and lines.
/// Another idea would be to make each line fragment an accessibility element, with options for navigating through
/// lines from there. The text view would then only handle text input, and lines would handle reading out useful data
/// to the user.
/// More research needs to be done for the best option here.~~
///
/// Consider that the system has access to the ``TextView/accessibilityVisibleCharacterRange`` and
/// ``TextView/accessibilityString(for:)`` methods. These can combine to allow an accessibility system to efficiently
/// query the text view's contents. Adding accessibility elements to line fragments would require hit testing them,
/// which will cause performance degradation.
extension TextView {
    override open func isAccessibilityElement() -> Bool {
        true
    }

    override open func isAccessibilityEnabled() -> Bool {
        true
    }

    override open func isAccessibilityFocused() -> Bool {
        isFirstResponder
    }

    override open func setAccessibilityFocused(_ accessibilityFocused: Bool) {
        guard !isFirstResponder else { return }
        window?.makeFirstResponder(self)
    }

    override open func accessibilityLabel() -> String? {
        "Text Editor"
    }

    override open func accessibilityRole() -> NSAccessibility.Role? {
        .textArea
    }

    override open func accessibilityValue() -> Any? {
        string
    }

    override open func setAccessibilityValue(_ accessibilityValue: Any?) {
        guard let string = accessibilityValue as? String else {
            return
        }

        self.string = string
    }

    override open func accessibilityString(for range: NSRange) -> String? {
        // `rangeOfComposedCharacterSequences` expands an empty mid-document range to cover the next character.
        // Checked before the intersection guard: an empty range at the document end doesn't "intersect" the
        // document range but is still a valid (empty) query.
        if range.isEmpty {
            return range.location >= 0 && range.location <= documentRange.max ? "" : nil
        }
        guard documentRange.intersection(range) == range else {
            return nil
        }

        return textStorage.substring(
            from: textStorage.mutableString.rangeOfComposedCharacterSequences(for: range)
        )
    }

    // MARK: Selections

    override open func accessibilitySelectedText() -> String? {
        let selectedRange = accessibilitySelectedTextRange()
        guard selectedRange != .notFound else {
            return nil
        }
        if selectedRange.isEmpty {
            return ""
        }
        let range = (textStorage.string as NSString).rangeOfComposedCharacterSequences(for: selectedRange)
        return textStorage.substring(from: range)
    }

    override open func accessibilitySelectedTextRange() -> NSRange {
        guard let selection = selectionManager
            .textSelections
            .sorted(by: { $0.range.lowerBound < $1.range.lowerBound })
            .first else {
            return .notFound
        }
        if selection.range.isEmpty {
            return selection.range
        }
        return textStorage.mutableString.rangeOfComposedCharacterSequences(for: selection.range)
    }

    override open func accessibilitySelectedTextRanges() -> [NSValue]? {
        selectionManager.textSelections.map { selection -> NSValue in
            if selection.range.isEmpty {
                return selection.range as NSValue
            }
            return textStorage.mutableString.rangeOfComposedCharacterSequences(for: selection.range) as NSValue
        }
    }

    override open func accessibilityInsertionPointLineNumber() -> Int {
        let selectedRange = accessibilitySelectedTextRange()
        guard selectedRange != .notFound,
              let linePosition = layoutManager.textLineForOffset(selectedRange.location) else {
            return -1
        }
        return linePosition.index
    }

    override open func setAccessibilitySelectedTextRange(_ accessibilitySelectedTextRange: NSRange) {
        // AX clients can legitimately send stale ranges (computed just before an edit shrank the document),
        // so clamp instead of storing a range that later range/string queries would raise on.
        let documentLength = textStorage.length
        let location = min(max(accessibilitySelectedTextRange.location, 0), documentLength)
        let length = min(max(accessibilitySelectedTextRange.length, 0), documentLength - location)
        selectionManager.setSelectedRange(NSRange(location: location, length: length))
    }

    override open func setAccessibilitySelectedTextRanges(_ accessibilitySelectedTextRanges: [NSValue]?) {
        let ranges = accessibilitySelectedTextRanges?.compactMap { $0 as? NSRange } ?? []
        selectionManager.setSelectedRanges(ranges)
    }

    // MARK: Text Ranges

    /// AX indexes and ranges are UTF-16 units, matching ``TextView/documentRange``, so this must report the
    /// UTF-16 length rather than a grapheme-cluster count.
    override open func accessibilityNumberOfCharacters() -> Int {
        textStorage.length
    }

    override open func accessibilityRange(forLine line: Int) -> NSRange {
        guard line >= 0 && layoutManager.lineStorage.count > line,
              let linePosition = layoutManager.textLineForIndex(line) else {
            return .notFound
        }
        return linePosition.range
    }

    /// - Parameter point: The point to test, in *screen* coordinates.
    override open func accessibilityRange(for point: NSPoint) -> NSRange {
        guard let windowPoint = window?.convertPoint(fromScreen: point) else {
            return .notFound
        }
        let localPoint = convert(windowPoint, from: nil)
        guard let location = layoutManager.textOffsetAtPoint(localPoint) else { return .notFound }
        return NSRange(location: location, length: 0)
    }

    override open func accessibilityRange(for index: Int) -> NSRange {
        guard index >= 0 && index < documentRange.length else { return .notFound }
        return textStorage.mutableString.rangeOfComposedCharacterSequence(at: index)
    }

    override open func accessibilityVisibleCharacterRange() -> NSRange {
        visibleTextRange ?? .notFound
    }

    /// The line index for a given character offset.
    override open func accessibilityLine(for index: Int) -> Int {
        guard index <= textStorage.length,
              let textLine = layoutManager.textLineForOffset(index) else {
            return -1
        }
        return textLine.index
    }

    /// - Returns: The bounding rect of the range's laid-out fragments, in *screen* coordinates.
    override open func accessibilityFrame(for range: NSRange) -> NSRect {
        guard documentRange.intersection(range) == range else {
            return .zero
        }
        if range.isEmpty {
            return .zero
        }
        let localRect = layoutManager.rectsFor(range: range).boundingRect()
        let windowRect = convert(localRect, to: nil)
        return window?.convertToScreen(windowRect) ?? .zero
    }
}
