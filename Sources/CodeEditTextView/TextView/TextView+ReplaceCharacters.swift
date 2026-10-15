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
    ///
    /// All ranges are replaced inside one storage transaction, highest location first so earlier ranges keep their
    /// offsets. The attributed string is created once for every range, and selections are shifted once for the whole
    /// batch rather than once per range.
    /// - Parameters:
    ///   - ranges: The ranges to replace
    ///   - string: The string to insert in the ranges.
    ///   - skipUpdateSelection: Skips the selection update step
    public func replaceCharacters(
        in ranges: [NSRange],
        with string: String,
        skipUpdateSelection: Bool = false
    ) {
        guard isEditable else { return }
        NotificationCenter.default.post(name: Self.textWillChangeNotification, object: self)
        // Open a layout transaction for the whole editing window so `willReplace`/`didReplace` delegate callbacks
        // (client code) cannot trigger a layout pass against mutated-storage/stale-lineStorage state.
        layoutManager.beginTransaction()
        textStorage.beginEditing()

        // Pre-compute the attributed string once for all ranges instead of allocating per-range.
        let attributedString = NSAttributedString(string: string, attributes: typingAttributes)
        let replacementLength = (string as NSString).length

        // Fast path: single range skips sorting entirely; multi-range sorts descending.
        // We iterate in reverse-location order so earlier ranges' offsets aren't invalidated by later edits.
        if ranges.count == 1 {
            applyReplacement(
                in: clampedEditRange(ranges[0], upperBound: textStorage.length),
                string: string,
                attributedString: attributedString,
                replacementLength: replacementLength,
                skipUpdateSelection: skipUpdateSelection
            )
        } else {
            // One user gesture applied at multiple cursors must land in a single undo group.
            let shouldGroupUndo = !(_undoManager?.isGrouping ?? true)
            if shouldGroupUndo {
                _undoManager?.beginUndoGrouping()
            }
            // Sort descending by location so each edit doesn't shift ranges that follow.
            let sortedRanges = ranges.sorted(by: { $0.location > $1.location })
            // Each range is clamped against the lowest offset edited so far (which starts as the storage length),
            // so an overlapping or out-of-bounds range from an external caller edits at most the untouched prefix
            // instead of raising or double-editing text a prior range already replaced.
            var editedLowerBound = textStorage.length
            // Applied ranges, in application order: selections are shifted once for the whole batch rather than once
            // per range (O(N·K) for N selections and K ranges), and the layout manager replays them one by one.
            var appliedRanges: [NSRange] = []
            appliedRanges.reserveCapacity(sortedRanges.count)
            for uncheckedRange in sortedRanges {
                let range = clampedEditRange(uncheckedRange, upperBound: editedLowerBound)
                let applied = applyReplacement(
                    in: range,
                    string: string,
                    attributedString: attributedString,
                    replacementLength: replacementLength,
                    skipUpdateSelection: true
                )
                if applied {
                    editedLowerBound = range.location
                    appliedRanges.append(range)
                }
            }
            if !skipUpdateSelection {
                selectionManager.didReplaceCharacters(in: appliedRanges, replacementLength: replacementLength)
            }
            // `NSTextStorage` reports the whole transaction as one edited range spanning every range; hand the layout
            // manager the real edits so it updates only the lines they touch.
            layoutManager.pendingCharacterEdits = appliedRanges.map { ($0, replacementLength) }
            if shouldGroupUndo {
                _undoManager?.endUndoGrouping()
            }
        }

        textStorage.endEditing()
        // Consumed by the edit processing `endEditing()` ran; cleared in case none ran (every range was rejected).
        layoutManager.pendingCharacterEdits = nil
        layoutManager.endTransaction()

        if !skipUpdateSelection {
            selectionManager.notifyAfterEdit()
        }
        NotificationCenter.default.post(name: Self.textDidChangeNotification, object: self)

        // `scrollSelectionToVisible` is a little expensive to call every time. Instead we just check if the first
        // selection is entirely visible. `.contains` checks that all points in the rect are inside.
        // The selection's cached `boundingRect` is stale until the next layout pass, so the caret's post-edit
        // position is measured from layout directly. Batch callers (undo/redo) pass `skipUpdateSelection` and
        // update selections and scroll themselves once all mutations are applied.
        if !skipUpdateSelection, let selection = selectionManager.textSelections.first {
            let selectionRect = layoutManager.rectForOffset(selection.range.location) ?? selection.boundingRect
            // `unobscuredVisibleRect`, not `visibleRect`: a caret sitting under the host's chrome is on screen
            // but not readable, and must still scroll into view.
            if !unobscuredVisibleRect.contains(selectionRect) {
                scrollSelectionToVisible()
            }
        }
    }

    /// Applies several replacements as one edit: one will/did-change notification pair, one storage transaction and
    /// one line-storage resync, with the delegate consulted per replacement exactly as ``replaceCharacters(in:with:skipUpdateSelection:)``
    /// does. The selection is left to the caller.
    ///
    /// Undo and redo replay a mutation group through this. Replaying one mutation per transaction cost a
    /// `processEditing` pass and a line-storage resync per keystroke undone; batching restores the single pass a
    /// coalesced group of 200 keystrokes deserves, and observers of ``textDidChangeNotification`` see one
    /// consistent post-replay document instead of 200 intermediate ones.
    /// - Parameter replacements: Ranges and replacement strings, applied in order; each range is interpreted in
    ///   the document as left by the previous replacement.
    func replaceCharacters(batch replacements: [(range: NSRange, string: String)]) {
        guard isEditable, !replacements.isEmpty else { return }
        NotificationCenter.default.post(name: Self.textWillChangeNotification, object: self)
        layoutManager.beginTransaction()
        textStorage.beginEditing()

        for replacement in replacements {
            applyReplacement(
                in: clampedEditRange(replacement.range, upperBound: textStorage.length),
                string: replacement.string,
                attributedString: NSAttributedString(string: replacement.string, attributes: typingAttributes),
                replacementLength: (replacement.string as NSString).length,
                skipUpdateSelection: true
            )
        }

        textStorage.endEditing()
        layoutManager.endTransaction()
        NotificationCenter.default.post(name: Self.textDidChangeNotification, object: self)
    }

    /// Validates and applies a single replacement inside an open edit transaction.
    /// - Returns: Whether the replacement was applied (the delegate may reject it, and empty edits are skipped).
    @discardableResult
    private func applyReplacement(
        in range: NSRange,
        string: String,
        attributedString: NSAttributedString,
        replacementLength: Int,
        skipUpdateSelection: Bool
    ) -> Bool {
        guard !range.isEmpty || !string.isEmpty,
              delegate?.textView(self, shouldReplaceContentsIn: range, with: string) ?? true else {
            return false
        }
        delegate?.textView(self, willReplaceContentsIn: range, with: string)
        _undoManager?.registerMutation(
            TextMutation(string: string, range: range, limit: textStorage.length)
        )
        textStorage.replaceCharacters(in: range, with: attributedString)
        if !skipUpdateSelection {
            selectionManager.didReplaceCharacters(in: range, replacementLength: replacementLength)
        }
        delegate?.textView(self, didReplaceContentsIn: range, with: string)
        return true
    }

    /// Clamps an externally-supplied edit range to `0...upperBound` so an invalid range edits at most the
    /// clamped region instead of raising on the storage.
    private func clampedEditRange(_ range: NSRange, upperBound: Int) -> NSRange {
        let end = min(max(range.max, 0), upperBound)
        let location = min(max(range.location, 0), end)
        return NSRange(location: location, length: end - location)
    }

    /// Replace the characters in a range with a new string.
    /// - Parameters:
    ///   - range: The range to replace.
    ///   - string: The string to insert in the range.
    ///   - skipUpdateSelection: Skips the selection update step
    public func replaceCharacters(
        in range: NSRange,
        with string: String,
        skipUpdateSelection: Bool = false
    ) {
        replaceCharacters(in: [range], with: string, skipUpdateSelection: skipUpdateSelection)
    }

    /// Iterates over all text selections in the `TextView` and applies the provided callback.
    ///
    /// This method is typically used when you need to perform an operation on each text selection in the editor,
    /// such as adjusting indentation, or other selection-based operations. The callback
    /// is executed for each selection, and you can modify the selection or perform related tasks.
    ///
    /// - Parameters:
    /// - callback: A closure that will be executed for each selection in the `TextView`. It takes two parameters:
    /// a `TextView` instance, allowing access to the view's properties and methods and a
    /// `TextSelectionManager.TextSelection` representing the current selection to operate on.
    ///
    /// - Note: The selections are iterated in reverse order, so modifications to earlier selections won't affect later
    ///   ones. The method automatically calls `notifyAfterEdit()` on the `selectionManager` after all
    ///   selections are processed.
    public func editSelections(callback: (TextView, TextSelectionManager.TextSelection) -> Void) {
        // One host operation applied at multiple cursors (indent, comment toggle) must land in a single undo
        // group, exactly like the multi-range branch of `replaceCharacters(in:with:)`.
        let shouldGroupUndo = selectionManager.textSelections.count > 1 && !(_undoManager?.isGrouping ?? true)
        if shouldGroupUndo {
            _undoManager?.beginUndoGrouping()
        }
        for textSelection in selectionManager.textSelections.reversed() {
            callback(self, textSelection)
        }
        if shouldGroupUndo {
            _undoManager?.endUndoGrouping()
        }
        selectionManager.notifyAfterEdit(force: true)
    }
}
