//
//  TextLayoutManager+AttributeFixing.swift
//  CodeEditTextView
//

import AppKit

// MARK: - Performance notes
//
// `NSTextStorage` fixes attributes lazily. A document load marks the whole string as needing fixing, and while
// *anything* is pending the storage fixes in 64K-unit chunks: the first attribute read after an edit re-fixes
// the entire chunk around the edit (about 1ms - the font fixer costs ~15ns per character), and the edit is
// reported to delegates as spanning its whole paragraph, so the layout manager rebuilt the line instead of
// resizing it and re-typeset it and its neighbor. That was a 6x regression in edit-then-layout.
//
// Once nothing is pending the storage fixes each edit eagerly and precisely (a one-character insert fixes one
// character), edits are reported with their exact range, and `ensureAttributesAreFixed` over the whole
// document returns in well under a microsecond. Nothing short of fixing the whole document reaches that state:
// `fixAttributes(in:)` on any sub-range fixes everything, and a partially fixed document still re-fixes chunks.
//
// So the whole document is fixed once after every load, in slices on the main queue after the first paint,
// because inline it would cost ~15ns per character on the open path (~35ms for 2MB). The chunk re-fix only
// bites when attributes are read after an edit, which is what a layout pass does; so a pass that runs after an
// edit while slices are still outstanding finishes the fix first. Opening never pays, editing without laying
// out never pays, and the one-time cost is spent exactly where it would otherwise be paid per keystroke.

extension TextLayoutManager {
    /// Units fixed per main-queue slice: roughly 2ms of work, short enough to interleave with input.
    static let attributeFixSliceLength = 131_072

    /// Marks the storage as freshly loaded and starts fixing its attributes in slices.
    ///
    /// Each slice re-checks that the storage is still the one it was scheduled for; a swap mid-way abandons the
    /// old work, and the new storage schedules its own. Edits that land between slices are harmless: the final
    /// state is "nothing pending" either way.
    func scheduleAttributeFixing() {
        attributesPendingFix = textStorage != nil
        editedSinceLoad = false
        fixAttributeSlice(from: 0)
    }

    private func fixAttributeSlice(from location: Int) {
        guard let textStorage else { return }
        Task { @MainActor [weak self, weak textStorage] in
            guard let self, let textStorage, self.textStorage === textStorage, self.attributesPendingFix else {
                return
            }
            let length = textStorage.length
            let end = min(location + Self.attributeFixSliceLength, length)
            if location < end {
                textStorage.ensureAttributesAreFixed(in: NSRange(location: location, length: end - location))
            }
            if end < length {
                self.fixAttributeSlice(from: end)
            } else {
                self.attributesPendingFix = false
            }
        }
    }

    /// Called at the start of a layout pass. If the document was edited before the slices finished, typesetting
    /// the edited lines would re-fix a 64K chunk each; finishing the whole fix here costs the same once and
    /// leaves every later edit eager and precise.
    func finishAttributeFixingIfEditedBeforeLayout() {
        guard attributesPendingFix, editedSinceLoad, let textStorage else { return }
        textStorage.ensureAttributesAreFixed(in: NSRange(location: 0, length: textStorage.length))
        attributesPendingFix = false
    }
}
