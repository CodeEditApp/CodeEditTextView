//
//  TextView+CopyPaste.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 8/21/23.
//

import AppKit

extension TextView {
    @objc open func copy(_ sender: AnyObject) {
        // Caret-only (empty) selections must not clobber the pasteboard, matching the standard macOS text system.
        guard let textSelections = selectionManager?
            .textSelections
            .filter({ !$0.range.isEmpty })
            .map({ textStorage.attributedSubstring(from: $0.range) }),
              !textSelections.isEmpty else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(textSelections)
    }

    @objc open func paste(_ sender: AnyObject) {
        guard let stringContents = NSPasteboard.general.string(forType: .string) else { return }
        insertText(stringContents, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    @objc open func cut(_ sender: AnyObject) {
        // Cut with only carets is a no-op: nothing is copied, and no text may be deleted.
        guard selectionManager?.textSelections.contains(where: { !$0.range.isEmpty }) == true else {
            return
        }
        copy(sender)
        deleteBackward(sender)
    }

    @objc open func delete(_ sender: AnyObject) {
        deleteBackward(sender)
    }
}
