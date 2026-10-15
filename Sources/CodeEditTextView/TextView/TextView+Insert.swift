//
//  TextView+Insert.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 9/3/23.
//

import AppKit

extension TextView {
    override public func insertNewline(_ sender: Any?) {
        let attachments: [AnyTextAttachment] = selectionManager.textSelections.compactMap({ selection in
            let content = layoutManager.contentRun(at: selection.range.location)
            if case let .attachment(attachment) = content?.data, attachment.range == selection.range {
                return attachment
            }
            return nil
        })

        if !attachments.isEmpty {
            for attachment in attachments.sorted(by: { $0.range.location > $1.range.location }) {
                performAttachmentAction(attachment: attachment)
            }
            return
        }

        insertText(layoutManager.detectedLineEnding.rawValue)
    }

    override public func insertTab(_ sender: Any?) {
        insertText("\t")
    }

    override public func yank(_ sender: Any?) {
        let strings = KillRing.shared.yank()
        insertMultipleString(strings)
    }

    /// Not documented or in any headers, but required if kill ring size > 1.
    /// From Cocoa docs: "note that yankAndSelect: is not listed in any headers"
    @objc func yankAndSelect(_ sender: Any?) {
        let strings = KillRing.shared.yankAndSelect()
        insertMultipleString(strings)
    }

    private func insertMultipleString(_ strings: [String]) {
        let selectedRanges = selectionManager.textSelections.map(\.range)

        guard !selectedRanges.isEmpty && !strings.isEmpty else { return }

        // One yank gesture across multiple cursors must land in a single undo group.
        let shouldGroupUndo = !(_undoManager?.isGrouping ?? true)
        if shouldGroupUndo {
            _undoManager?.beginUndoGrouping()
        }
        for idx in (0..<selectedRanges.count).reversed() {
            let range = selectedRanges[idx]

            if idx == selectedRanges.count - 1 && idx < strings.count - 1 {
                // Last range, still have strings remaining. Concatenate them.
                let remainingString = strings[idx..<strings.count].joined(separator: "\n")
                replaceCharacters(in: range, with: remainingString)
            } else {
                // With more cursors than strings, the last string is repeated at the extra cursors.
                replaceCharacters(in: range, with: strings[min(idx, strings.count - 1)])
            }
        }
        if shouldGroupUndo {
            _undoManager?.endUndoGrouping()
        }
    }
}
