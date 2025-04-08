//
//  TextSelectionManager+Update.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 10/22/23.
//

import Foundation
import AppKit

extension TextSelectionManager: NSTextStorageDelegate {
    public func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }

        for textSelection in self.textSelections {
            // If the text selection is ahead of the edited range, move it back by the range's length
            if textSelection.range.location > editedRange.max {
                textSelection.range.location += delta
                textSelection.range.length = 0
            } else if textSelection.range.intersection(editedRange) != nil {
                textSelection.range.location = editedRange.max
                textSelection.range.length = 0
            } else {
                textSelection.range.length = 0
            }
        }

        // Clean up duplicate selection ranges
        var allRanges: Set<NSRange> = []
        for (idx, selection) in self.textSelections.enumerated().reversed() {
            if allRanges.contains(selection.range) {
                self.textSelections.remove(at: idx)
            } else {
                allRanges.insert(selection.range)
            }
        }

        notifyAfterEdit()
    }

    func notifyAfterEdit() {
        updateSelectionViews()
        NotificationCenter.default.post(Notification(name: Self.selectionChangedNotification, object: self))
    }
}
