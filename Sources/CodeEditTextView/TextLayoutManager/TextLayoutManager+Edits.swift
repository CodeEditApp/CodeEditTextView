//
//  TextLayoutManager+Edits.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 9/3/23.
//

import AppKit

// MARK: - Edits

extension TextLayoutManager: NSTextStorageDelegate {
    /// Receives edit notifications from the text storage and updates internal data structures to stay in sync with
    /// text content.
    ///
    /// If the changes are only attribute changes, this method invalidates layout for the edited range and returns.
    ///
    /// Otherwise, any lines that were removed or replaced by the edit are first removed from the text line layout
    /// storage. Then, any new lines are inserted into the same storage.
    ///
    /// For instance, if inserting a newline this method will:
    /// - Remove no lines (none were replaced)
    /// - Update the current line's range to contain the newline character.
    /// - Insert a new line after the current line.
    ///
    /// If a selection containing a newline is deleted and replaced with two more newlines this method will:
    /// - Delete the original line.
    /// - Insert two lines.
    ///
    /// - Note: This method *does not* cause a layout calculation. If a method is finding `NaN` values for line
    ///         fragments, ensure `layout` or `ensureLayoutUntil` are called on the subject ranges.
    public func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else {
            if editedMask.contains(.editedAttributes) && delta == 0 {
                invalidateLayoutForRange(editedRange)
            }
            return
        }

        if let edits = takePendingCharacterEdits(matching: editedRange, delta: delta) {
            // Replay the edits from the lowest up. At each step every lower edit is already in the line storage and
            // no higher one is, so line-storage offsets equal final text offsets up to the end of the current edit,
            // and the single-edit logic below reads the right characters.
            var shift = 0
            for edit in edits.reversed() {
                let editDelta = edit.replacementLength - edit.range.length
                applyCharacterEdit(
                    editedRange: NSRange(location: edit.range.location + shift, length: edit.replacementLength),
                    delta: editDelta
                )
                shift += editDelta
            }
        } else {
            applyCharacterEdit(editedRange: editedRange, delta: delta)
        }
    }

    /// Returns ``pendingCharacterEdits`` if they account exactly for the processed edit, and clears them either way.
    ///
    /// They must not touch each other (two edits sharing a boundary could split a CR LF pair between them, which
    /// the per-edit seam repair cannot see), and together they must produce exactly the edited range and length
    /// change `NSTextStorage` reported. Otherwise, for instance when a delegate edited the text inside the same
    /// transaction, the merged range is processed as one edit, as before.
    private func takePendingCharacterEdits(
        matching editedRange: NSRange,
        delta: Int
    ) -> [(range: NSRange, replacementLength: Int)]? {
        guard let edits = pendingCharacterEdits else { return nil }
        pendingCharacterEdits = nil
        guard edits.count > 1, let lowest = edits.last, let highest = edits.first else { return nil }
        var totalDelta = 0
        var previousLocation = Int.max
        for edit in edits {
            // Strictly descending, with unedited text between neighbors.
            guard edit.range.max < previousLocation else { return nil }
            previousLocation = edit.range.location
            totalDelta += edit.replacementLength - edit.range.length
        }
        let highestEditDelta = highest.replacementLength - highest.range.length
        let finalEnd = highest.range.location + (totalDelta - highestEditDelta) + highest.replacementLength
        guard totalDelta == delta,
              editedRange.location == lowest.range.location,
              editedRange.max == finalEnd else {
            return nil
        }
        return edits
    }

    /// Updates the line storage for one character edit.
    /// - Parameters:
    ///   - editedRange: The range of the new characters in the post-edit text.
    ///   - delta: The change in length.
    private func applyCharacterEdit(editedRange: NSRange, delta: Int) {
        editedSinceLoad = true
        let lineCountBefore = lineStorage.count

        let insertedStringRange = NSRange(location: editedRange.location, length: editedRange.length - delta)

        // Capture the line span of the replaced region before mutating the line storage - post-edit lookups can't
        // recover how many lines the replaced range used to span.
        let firstEditedLineIndex: Int
        if editedRange.location >= lineStorage.length {
            firstEditedLineIndex = max(lineStorage.count - 1, 0)
        } else {
            firstEditedLineIndex = lineStorage.lineSpan(atOffset: editedRange.location)?.index ?? 0
        }
        let lastEditedLineIndexBefore: Int
        if insertedStringRange.max >= lineStorage.length {
            lastEditedLineIndexBefore = max(lineStorage.count - 1, firstEditedLineIndex)
        } else {
            lastEditedLineIndexBefore = lineStorage.lineSpan(atOffset: insertedStringRange.max)?.index
                ?? firstEditedLineIndex
        }

        removeLayoutLinesIn(range: insertedStringRange)
        insertNewLines(for: editedRange)
        repairLineEndingSeams(around: editedRange)

        // Adjust view zone line numbers if the line count changed.
        let lineCountAfter = lineStorage.count
        let lineDelta = lineCountAfter - lineCountBefore
        if lineDelta != 0, !viewZones.zones.isEmpty {
            viewZones.adjustLineNumbers(afterLine: firstEditedLineIndex, delta: lineDelta)
        }

        // Adjust line decoration ranges if the line count changed.
        if lineDelta != 0, lineDecorations.count > 0 {
            let oldLineCount = lastEditedLineIndexBefore - firstEditedLineIndex + 1
            lineDecorations.adjustForEdit(
                editLineStart: firstEditedLineIndex,
                oldLineCount: oldLineCount,
                newLineCount: max(1, oldLineCount + lineDelta)
            )
        }

        let removedAttachments = attachments.textUpdated(replacedRange: insertedStringRange, delta: delta)

        invalidateLayoutForRange(insertedStringRange)
        // A removed attachment had folded its lines into the line it starts on, whose fragments still draw it. That
        // line may lie before the edit, outside the range invalidated above.
        for attachment in removedAttachments where attachment.range.location < insertedStringRange.location {
            invalidateLayoutForRange(NSRange(location: attachment.range.location, length: 0))
        }
    }

    /// Removes all lines in the range, as if they were deleted. This is a setup for inserting the lines back in on an
    /// edit.
    /// - Parameter range: The range that was deleted.
    private func removeLayoutLinesIn(range: NSRange) {
        // Collect all line positions in the range first, snapshotting their indices in reverse order.
        // We use indices rather than offsets because after each tree mutation the offsets shift, but re-fetching
        // by index is stable (we process in reverse order so lower indices remain valid).
        // Spans, not positions: the walk must not create a `TextLine` for every line it is about to delete.
        let lineIndices = lineStorage.lineSpans(in: range).map(\.index).reversed()
        guard !lineIndices.isEmpty else { return }

        for lineIndex in lineIndices {
            // Re-fetch the line by index to get a fresh position after prior mutations.
            guard let freshPosition = lineStorage.lineSpan(atIndex: lineIndex) else { continue }
            guard let intersection = freshPosition.range.intersection(range), !intersection.isEmpty else { continue }

            if intersection == freshPosition.range && freshPosition.range.max != lineStorage.length {
                // Delete line entirely
                lineStorage.delete(lineAt: freshPosition.range.location)
            } else if intersection.max == freshPosition.range.max,
                      intersection.location == freshPosition.range.location
                        || !prefixEndsWithLineTerminator(at: intersection.location),
                      let nextLine = lineStorage.lineSpan(atOffset: freshPosition.range.max) {
                // Need to merge line with one after it after updating this line to remove the end of the line.
                // Capture merge delta before mutating the tree.
                let mergeDelta = -intersection.length + nextLine.range.length
                lineStorage.delete(lineAt: nextLine.range.location)
                if mergeDelta != 0 {
                    lineStorage.update(
                        atOffset: freshPosition.range.location,
                        delta: mergeDelta,
                        deltaHeight: 0
                    )
                }
            } else {
                lineStorage.update(
                    atOffset: freshPosition.range.location,
                    delta: -intersection.length,
                    deltaHeight: 0
                )
            }
        }
    }

    /// Determines whether the text surviving before a tail deletion still ends with a line terminator in the
    /// post-edit text. Deleting only the `\n` of a `\r\n` pair leaves a valid `\r` line ending, so the line must not
    /// be merged with its successor.
    /// - Parameter offset: The offset the deletion begins at. The character before it is the prefix's last character.
    /// - Returns: True if the character before `offset` terminates a line in the post-edit text.
    private func prefixEndsWithLineTerminator(at offset: Int) -> Bool {
        guard offset > 0, let string = textStorage?.mutableString else { return false }
        let previousChar = string.character(at: offset - 1)
        if previousChar == 0x0A { // \n
            return true
        }
        if previousChar == 0x0D { // \r
            // A `\r` terminates the line unless the post-edit text continues with `\n`, forming a CRLF pair.
            return offset >= string.length || string.character(at: offset) != 0x0A
        }
        return false
    }

    /// An edit can split a CRLF pair across two storage lines: inserting `\n` directly after an existing `\r`,
    /// inserting `\r` directly before an existing `\n`, or deleting the text separating a `\r` from a following `\n`.
    /// `NSString` treats CRLF as a single line terminator, so the pair must live on one storage line. Checks both edit
    /// seams and merges the split pair's lines when found.
    /// - Parameter editedRange: The range of the inserted string in the post-edit text.
    private func repairLineEndingSeams(around editedRange: NSRange) {
        repairLineEndingSeam(at: editedRange.location)
        splitLineAfterUnpairedCarriageReturn(at: editedRange.location)
        if editedRange.length > 0 {
            repairLineEndingSeam(at: editedRange.max)
        }
    }

    /// The opposite seam: inserting text between the `\r` and `\n` of a CR LF pair leaves the `\r` ending a line on
    /// its own, but the storage line that held the pair still runs past it (the insert only grew that line). Splits
    /// the line right after the `\r`.
    /// - Parameter offset: The offset just after the potential `\r`.
    private func splitLineAfterUnpairedCarriageReturn(at offset: Int) {
        guard offset > 0,
              let string = textStorage?.mutableString,
              offset < string.length,
              string.character(at: offset - 1) == 0x0D, // \r
              string.character(at: offset) != 0x0A, // not \n
              let line = lineStorage.lineSpan(atOffset: offset - 1),
              line.range.max > offset else {
            return
        }
        let existingLine = lineStorage.existingData(at: line.handle)
        let tailLength = line.range.max - offset
        lineStorage.insertLine(atOffset: line.range.max, length: tailLength, height: estimateLineHeight())
        lineStorage.update(atOffset: line.range.location, delta: -tailLength, deltaHeight: 0)
        existingLine?.setNeedsLayout()
    }

    /// If a CRLF pair straddles a storage line boundary at the given offset, absorbs the `\n` line into the line
    /// ending in `\r`.
    /// - Parameter offset: The offset between the potential `\r` and `\n` characters.
    private func repairLineEndingSeam(at offset: Int) {
        guard offset > 0,
              let string = textStorage?.mutableString,
              offset < string.length,
              string.character(at: offset - 1) == 0x0D, // \r
              string.character(at: offset) == 0x0A, // \n
              let lineAfter = lineStorage.lineSpan(atOffset: offset),
              lineAfter.range.location == offset else {
            return
        }
        lineStorage.delete(lineAt: offset)
        lineStorage.update(atOffset: offset - 1, delta: lineAfter.range.length, deltaHeight: 0)
        if let mergedLine = lineStorage.lineSpan(atOffset: offset - 1) {
            lineStorage.existingData(at: mergedLine.handle)?.setNeedsLayout()
        }
    }

    /// Inserts any newly inserted lines into the line layout storage. Exits early if the range is empty.
    /// - Parameter range: The range of the string that was inserted into the text storage.
    private func insertNewLines(for range: NSRange) {
        guard !range.isEmpty, let textStorage else { return }
        // Scan the inserted range in place with the scanner the document build uses (see `UTF16LineScanner`), so
        // edits produce the line structure a fresh open would. `textStorage.string as NSString` is the storage's live
        // backing string - read here, synchronously, nothing is copied but the window of units being scanned.
        var location = range.location
        (textStorage.string as NSString).forEachLine(in: range) { length, terminator in
            // `\n`, `\r` and `\r\n` open a new storage line; a final piece without one (terminator 0) does not.
            applyLineInsert(
                length: length,
                endsWithLineEnding: terminator == 0x0A || terminator == 0x0D,
                at: location
            )
            location += length
        }
    }

    /// Applies a line insert to the internal line storage tree.
    /// - Parameters:
    ///   - length: The UTF-16 length of the inserted line, including its line ending if it has one.
    ///   - endsWithLineEnding: Whether the inserted line ends with `\n`, `\r` or `\r\n`.
    ///   - location: The location the line is being inserted into.
    private func applyLineInsert(length: Int, endsWithLineEnding: Bool, at location: Int) {
        if endsWithLineEnding {
            if location == lineStorage.length {
                // Insert a new line at the end of the document, need to insert a new line 'cause there's nothing to
                // split. Also, append the new text to the last line.
                lineStorage.update(atOffset: location, delta: length, deltaHeight: 0.0)
                lineStorage.insertLine(atOffset: location + length, length: 0, height: estimateLineHeight())
            } else {
                // Need to split the line inserting into and create a new line with the split section of the line.
                guard let linePosition = lineStorage.lineSpan(atOffset: location) else { return }
                // Capture splitLength before any tree mutations so it uses the fresh linePosition.
                let splitLength = linePosition.range.max - location
                let lineDelta = length - splitLength // The difference in the line being edited

                // First, insert the new split line. We do this before updating the current line to avoid
                // using stale values after tree rebalancing.
                lineStorage.insertLine(atOffset: linePosition.range.max, length: splitLength, height: estimateLineHeight())

                // Now update the current line's length. The inserted string replaces the portion that was
                // split off, so the net delta on this line is `length - splitLength`.
                if lineDelta != 0 {
                    lineStorage.update(atOffset: location, delta: lineDelta, deltaHeight: 0.0)
                }
            }
        } else {
            lineStorage.update(atOffset: location, delta: length, deltaHeight: 0.0)
        }
    }
}
