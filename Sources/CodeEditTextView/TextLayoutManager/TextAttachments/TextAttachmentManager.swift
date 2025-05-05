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
    private var orderedAttachments: [AnyTextAttachment] = []
    weak var layoutManager: TextLayoutManager?

    /// Adds a new attachment, keeping `orderedAttachments` sorted by range.location.
    /// If two attachments overlap, the layout phase will later ignore the one with the higher start.
    /// - Complexity: `O(n log(n))` due to array insertion. Could be improved with a binary tree.
    public func add(_ attachment: any TextAttachment, for range: NSRange) {
        let attachment = AnyTextAttachment(range: range, attachment: attachment)
        let insertIndex = findInsertionIndex(for: range.location)
        orderedAttachments.insert(attachment, at: insertIndex)
        layoutManager?.lineStorage.linesInRange(range).dropFirst().forEach {
            if $0.height != 0 {
                layoutManager?.lineStorage.update(atOffset: $0.range.location, delta: 0, deltaHeight: -$0.height)
            }
        }
        layoutManager?.setNeedsLayout()
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
    public func get(startingIn range: NSRange) -> [AnyTextAttachment] {
        var results: [AnyTextAttachment] = []
        var idx = findInsertionIndex(for: range.location)
        while idx < orderedAttachments.count {
            let attachment = orderedAttachments[idx]
            let loc = attachment.range.location
            if loc >= range.upperBound {
                break
            }
            if range.contains(loc) {
                if let lastResult = results.last, !lastResult.range.contains(attachment.range.location) {
                    results.append(attachment)
                } else if results.isEmpty {
                    results.append(attachment)
                }
            }
            idx += 1
        }
        return results
    }

    /// Returns all attachments whose ranges overlap the given query range.
    ///
    /// - Parameter query: The `NSRange` to test for overlap.
    /// - Returns: An array of `AnyTextAttachment` instances whose ranges intersect `query`.
    public func get(overlapping query: NSRange) -> [AnyTextAttachment] {
        // Find the first attachment whose end is beyond the start of the query.
        guard let startIdx = firstIndex(where: { $0.range.upperBound > query.location }) else {
            return []
        }

        var results: [AnyTextAttachment] = []
        var idx = startIdx

        // Collect every subsequent attachment that truly overlaps the query.
        while idx < orderedAttachments.count {
            let attachment = orderedAttachments[idx]
            if attachment.range.location >= query.upperBound {
                break
            }
            if NSIntersectionRange(attachment.range, query).length > 0,
               results.last?.range != attachment.range {
                results.append(attachment)
            }
            idx += 1
        }

        return results
    }

    package func textUpdated(atOffset: Int, delta: Int) {
        for (idx, attachment) in orderedAttachments.enumerated().reversed() {
            if attachment.range.contains(atOffset) {
                orderedAttachments.remove(at: idx)
            } else if attachment.range.location > atOffset {
                orderedAttachments[idx].range.location += delta
            }
        }
    }
}

private extension TextAttachmentManager {
    /// Binary-searches `orderedAttachments` and returns the smallest index
    /// at which `predicate(attachment)` is true (i.e. the lower-bound index).
    ///
    /// - Note: always returns a value in `0...orderedAttachments.count`.
    ///         If it returns `orderedAttachments.count`, no element satisfied
    ///         the predicate, but that’s still a valid insertion point.
    func lowerBoundIndex(
        where predicate: (AnyTextAttachment) -> Bool
    ) -> Int {
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
        return low
    }

    /// Returns the index in `orderedAttachments` at which an attachment whose
    /// `range.location == location` *could* be inserted, keeping the array sorted.
    ///
    /// - Parameter location: the attachment’s `range.location`
    /// - Returns: a valid insertion index in `0...orderedAttachments.count`
    func findInsertionIndex(for location: Int) -> Int {
        lowerBoundIndex { $0.range.location >= location }
    }

    /// Finds the first index whose attachment satisfies `predicate`.
    ///
    /// - Parameter predicate: the query predicate.
    /// - Returns: the first matching index, or `nil` if none of the
    ///            attachments satisfy the predicate.
    func firstIndex(where predicate: (AnyTextAttachment) -> Bool) -> Int? {
        let idx = lowerBoundIndex { predicate($0) }
        return idx < orderedAttachments.count ? idx : nil
    }
}
