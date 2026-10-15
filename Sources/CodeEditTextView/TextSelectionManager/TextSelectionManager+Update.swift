//
//  TextSelectionManager+Update.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 10/22/23.
//

import Foundation

extension TextSelectionManager {
    /// Shifts every selection to track an edit that has already been applied to the text storage.
    ///
    /// Deliberately does not invalidate anything, and must leave ``lastInvalidatedSelectionRects`` alone: those
    /// rects are where the selections were last *painted*, and they are the only record of the pixels this edit
    /// is about to strand. The repaint happens on the following layout pass, once the new geometry exists.
    public func didReplaceCharacters(in range: NSRange, replacementLength: Int) {
        let delta = replacementLength - range.length

        // Pass 1: adjust locations in-place. This is the only pass that runs for the (overwhelmingly common)
        // single-cursor case - we early-return before doing any dedup work.
        // Selections entirely before the edited range are untouched; selections at or after it shift by `delta`
        // keeping their length, so a multi-range replace leaves every pending selection tracking its own edit.
        for textSelection in textSelections {
            if textSelection.range.intersection(range) != nil
                || textSelection.range == range
                || (textSelection.range.isEmpty && textSelection.range.location == range.max) {
                textSelection.range.location = range.location + replacementLength
                textSelection.range.length = 0
            } else if textSelection.range.location >= range.max {
                textSelection.range.location = max(0, textSelection.range.location + delta)
            }
        }

        removeDuplicateSelections()
    }

    /// Shifts every selection to track a batch of edits that has already been applied in one transaction, the way the
    /// multi-range branch of ``TextView/replaceCharacters(in:with:skipUpdateSelection:)`` applies them.
    ///
    /// The result is exactly that of calling ``didReplaceCharacters(in:replacementLength:)`` once per range, in order.
    /// That costs O(N·K) for N selections and K ranges plus a dedup per range - with one cursor per range, a quarter
    /// of a 50-cursor keystroke. Here each selection binary-searches the ranges once and the dedup runs once.
    ///
    /// - Parameters:
    ///   - ranges: The replaced ranges in application order: descending by location, each ending at or before the
    ///     start of the one applied before it, so every range is in the coordinates of the original document.
    ///     Empty ranges must have a non-zero `replacementLength` (an empty replacement of nothing is not an edit).
    ///   - replacementLength: The UTF-16 length of the string inserted at every range.
    func didReplaceCharacters(in ranges: [NSRange], replacementLength: Int) {
        let rangeCount = ranges.count
        guard rangeCount > 1 else {
            if let range = ranges.first {
                didReplaceCharacters(in: range, replacementLength: replacementLength)
            }
            return
        }

        // Walk the ranges in ascending order; their locations and their ends are then both non-decreasing.
        func edit(_ index: Int) -> NSRange { ranges[rangeCount - 1 - index] }
        /// The first index in `0..<rangeCount` for which `isAbove` holds; `isAbove` must be false, then true.
        func partitionIndex(where isAbove: (Int) -> Bool) -> Int {
            var low = 0
            var high = rangeCount
            while low < high {
                let mid = (low + high) / 2
                if isAbove(mid) { high = mid } else { low = mid + 1 }
            }
            return low
        }

        withUnsafeTemporaryAllocation(of: Int.self, capacity: rangeCount + 1) { scratch in
            // shift[i]: the total length change made by the `i` lowest edits.
            guard let shift = scratch.baseAddress else { return }
            shift[0] = 0
            for index in 0..<rangeCount {
                shift[index + 1] = shift[index] + replacementLength - edit(index).length
            }

            for textSelection in textSelections {
                let range = textSelection.range
                // Applied one at a time, the first edit (highest location) that touches a selection decides its fate
                // and every edit below it then shifts it. An edit "intersects" a selection, collapsing it to the end
                // of the replacement, when either range's location lies inside the other (`NSRange.intersection`),
                // so a caret at a replaced range's start collapses too. Edits ending at or before the selection shift
                // it (a caret exactly at an edit's end collapses onto the same location).
                let editsBefore = partitionIndex { edit($0).max > range.location }
                var collapsingEdit = -1
                // The selection starts inside a replaced range. Replaced ranges are disjoint, so only the first one
                // ending after the selection's location can contain it.
                if editsBefore < rangeCount && edit(editsBefore).location <= range.location {
                    collapsingEdit = editsBefore
                }
                // An edit starts inside the selection: the highest one is applied first.
                if range.length > 0 {
                    let editsStartingBeforeEnd = partitionIndex { edit($0).location >= range.max }
                    if editsStartingBeforeEnd > 0 && edit(editsStartingBeforeEnd - 1).location >= range.location {
                        collapsingEdit = max(collapsingEdit, editsStartingBeforeEnd - 1)
                    }
                }
                if collapsingEdit >= 0 {
                    textSelection.range = NSRange(
                        location: edit(collapsingEdit).location + replacementLength + shift[collapsingEdit],
                        length: 0
                    )
                } else if shift[editsBefore] != 0 {
                    textSelection.range.location += shift[editsBefore]
                }
            }
        }

        removeDuplicateSelections()
    }

    /// Removes selections whose range duplicates an earlier selection's, keeping the first, and removes the dropped
    /// selections' cursor views.
    private func removeDuplicateSelections() {
        // Skip the Set allocation entirely for small N (almost always the case during typing -
        // multi-cursor sessions rarely exceed a handful of carets). The O(N²) scan is faster than Set<NSRange>
        // hashing for N≤16 because NSRange compares are 16 bytes of trivial integer comparison.
        let count = textSelections.count
        if count <= 1 { return }

        if count <= 16 {
            var writeIdx = 1
            outer: for readIdx in 1..<count {
                let candidate = textSelections[readIdx].range
                for keptIdx in 0..<writeIdx where textSelections[keptIdx].range == candidate {
                    // A dropped selection must also drop its cursor view - `view` is weak, but the view
                    // survives via its superview and would keep blinking as a ghost caret.
                    textSelections[readIdx].view?.removeFromSuperview()
                    continue outer
                }
                if writeIdx != readIdx {
                    textSelections[writeIdx] = textSelections[readIdx]
                }
                writeIdx += 1
            }
            if writeIdx < count {
                textSelections.removeSubrange(writeIdx...)
            }
        } else {
            var seen = Set<NSRange>(minimumCapacity: count)
            var writeIdx = 0
            for readIdx in 0..<count {
                let range = textSelections[readIdx].range
                if seen.insert(range).inserted {
                    if writeIdx != readIdx {
                        textSelections[writeIdx] = textSelections[readIdx]
                    }
                    writeIdx += 1
                } else {
                    // See the small-N branch: dropped duplicates must remove their cursor views.
                    textSelections[readIdx].view?.removeFromSuperview()
                }
            }
            if writeIdx < count {
                textSelections.removeSubrange(writeIdx...)
            }
        }
    }

    /// Called after an edit transaction completes. Posts the selection-changed notification and optionally forces an
    /// immediate cursor/selection view update.
    ///
    /// In the normal edit flow the visual update is deferred to the layout pass (`layout()` calls
    /// `updateSelectionViews(skipTimerReset: true)` after `layoutLines()`), avoiding a redundant double-update.
    /// Pass `force: true` from `editSelections` or similar entry points where no subsequent layout pass is guaranteed.
    ///
    /// That ordering is what makes the scoped selection invalidation safe for edits: `layoutLines()` dirties
    /// the band every moved fragment occupies before the selection update dirties the caret's old and new
    /// bands, and every one of those requests is serviced by the same `draw(_:)`. Forcing the update here
    /// instead only widens the result - the pre-layout rects become the *old* band of the layout pass's own
    /// selection update, so both geometries are still repainted.
    public func notifyAfterEdit(force: Bool = false) {
        if force {
            updateSelectionViews(force: true)
        } else if textView?.isFirstResponder ?? false {
            // The deferred visual update runs with `skipTimerReset: true`, so reset the blink here - the caret
            // must stay solid while typing, matching system text views.
            cursorTimer.resetTimer()
            resetSystemCursorTimers()
        }
        NotificationCenter.default.post(Notification(name: Self.selectionChangedNotification, object: self))
    }
}
