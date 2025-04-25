//
//  TextAttachmentManager.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 4/24/25.
//

import Foundation

/// Manages a set of attachments for the layout manager, provides methods for efficiently finding attachments for a
/// line range.
///
/// If two attachments are overlapping, the one placed further along in the document will be
/// ignored when laying out attachments.
public final class TextAttachmentManager {
    private var orderedAttachments: [TextAttachmentBox] = []
    weak var layoutManager: TextLayoutManager?

    /// Adds a new attachment box, keeping `orderedAttachments` sorted by range.location.
    /// If two attachments overlap, the layout phase will later ignore the one with the higher start.
    /// - Complexity: `O(n log(n))` due to array insertion. Could be improved with a binary tree.
    public func add(_ attachment: any TextAttachment, for range: NSRange) {
        let box = TextAttachmentBox(range: range, attachment: attachment)
        let insertIndex = findInsertionIndex(for: range.location)
        orderedAttachments.insert(box, at: insertIndex)
        layoutManager?.invalidateLayoutForRange(range)
    }

    public func remove(atOffset offset: Int) {
        let index = findInsertionIndex(for: offset)

        // Check if the attachment at this index starts exactly at the offset
        if index < orderedAttachments.count,
           orderedAttachments[index].range.location == offset {
            let invalidatedRange = orderedAttachments.remove(at: index).range
            layoutManager?.invalidateLayoutForRange(invalidatedRange)
        } else {
            assertionFailure("No attachment found at offset \(offset)")
        }
    }

    /// Finds attachments for the given line range, and returns them as an array.
    /// Returned attachment's ranges will be relative to the _document_, not the line.
    /// - Complexity: `O(n log(n))`, ideally `O(log(n))`
    public func attachments(in range: NSRange) -> [TextAttachmentBox] {
        var results: [TextAttachmentBox] = []
        var idx = findInsertionIndex(for: range.location)
        while idx < orderedAttachments.count {
            let box = orderedAttachments[idx]
            let loc = box.range.location
            if loc >= range.upperBound {
                break
            }
            if range.contains(loc) {
                results.append(box)
            }
            idx += 1
        }
        return results
    }
}

private extension TextAttachmentManager {
    /// Returns the index in `orderedAttachments` at which an attachment with
    /// `range.location == location` should be inserted to keep the array sorted.
    /// (Lower‐bound search.)
    func findInsertionIndex(for location: Int) -> Int {
        var low = 0
        var high = orderedAttachments.count
        while low < high {
            let mid = (low + high) / 2
            if orderedAttachments[mid].range.location < location {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}
