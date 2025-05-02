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
        layoutManager?.lineStorage.linesInRange(range).dropFirst().forEach {
            layoutManager?.lineStorage.update(atOffset: $0.range.location, delta: 0, deltaHeight: -$0.height)
        }
        layoutManager?.invalidateLayoutForRange(range)
    }

    public func remove(atOffset offset: Int) {
        let index = findInsertionIndex(for: offset)

        guard index < orderedAttachments.count && orderedAttachments[index].range.location == offset else {
            assertionFailure("No attachment found at offset \(offset)")
            return
        }

        let attachment = orderedAttachments.remove(at: index)
        layoutManager?.invalidateLayoutForRange(attachment.range)
    }

    /// Finds attachments starting in the given line range, and returns them as an array.
    /// Returned attachment's ranges will be relative to the _document_, not the line.
    /// - Complexity: `O(n log(n))`, ideally `O(log(n))`
    public func attachments(startingIn range: NSRange) -> [TextAttachmentBox] {
        var results: [TextAttachmentBox] = []
        var idx = findInsertionIndex(for: range.location)
        while idx < orderedAttachments.count {
            let box = orderedAttachments[idx]
            let loc = box.range.location
            if loc >= range.upperBound {
                break
            }
            if range.contains(loc) {
                if let lastResult = results.last, !lastResult.range.contains(box.range.location) {
                    results.append(box)
                } else if results.isEmpty {
                    results.append(box)
                }
            }
            idx += 1
        }
        return results
    }

    /// Returns all attachments whose ranges overlap the given query range.
    ///
    /// - Parameter query: The `NSRange` to test for overlap.
    /// - Returns: An array of `TextAttachmentBox` instances whose ranges intersect `query`.
    func attachments(overlapping query: NSRange) -> [TextAttachmentBox] {
        // Find the first attachment whose end is beyond the start of the query.
        guard let startIdx = firstIndex(where: { $0.range.upperBound > query.location }) else {
            return []
        }

        var results: [TextAttachmentBox] = []
        var idx = startIdx

        // Collect every subsequent attachment that truly overlaps the query.
        while idx < orderedAttachments.count {
            let box = orderedAttachments[idx]
            if box.range.location >= query.upperBound {
                break
            }
            if NSIntersectionRange(box.range, query).length > 0,
               results.last?.range != box.range {
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
    
    /// Finds the first index that matches a callback.
    /// - Parameter predicate: The query predicate.
    /// - Returns: The first index that matches the given predicate.
    func firstIndex(where predicate: (TextAttachmentBox) -> Bool) -> Int? {
        var low = 0
        var high = orderedAttachments.count
        while low < high {
            let mid = (low + high) / 2
            if predicate(orderedAttachments[mid]) {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low < orderedAttachments.count ? low : nil
    }
}
