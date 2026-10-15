//
//  TextLayoutManager+FragmentDiff.swift
//  CodeEditTextView
//
//  The y-band in which two consecutive passes' fragment lists differ - the pixels a redraw decision owes the
//  screen whenever the fragment list changes.
//

import AppKit

extension TextLayoutManager {
    /// The smallest y-band inside `clip` containing every difference between this pass's `visibleFragments` and
    /// the previous pass's, or `nil` when the two lists draw `clip` identically.
    ///
    /// Re-typeset lines always produce fresh `LineFragment` instances, so identity + geometry comparison is
    /// sufficient. Both lists are y-ordered, so a two-pointer merge finds the differing fragments in O(n) with
    /// no allocation: matched pairs advance both cursors, and a mismatch charges the fragment that sits higher
    /// in the document, which keeps a scrolled window (one fragment gained at the leading edge, one lost at the
    /// trailing edge) down to exactly those two fragments instead of the whole list. Differences from *both*
    /// lists count: a removed or moved fragment left pixels behind at its old position.
    ///
    /// Both lists are walked through raw buffer pointers and every comparison reads fields through those
    /// pointers. Binding a `VisibleFragment` value would copy the struct and retain/release its `LineFragment`
    /// on each of the ~300 iterations a live scroll frame performs, which is pure overhead for a float compare.
    func changedFragmentBand(in clip: NSRect) -> (minY: CGFloat, maxY: CGFloat)? {
        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude

        visibleFragments.withUnsafeBufferPointer { newBuffer in
            previousVisibleFragments.withUnsafeBufferPointer { oldBuffer in
                TextLayoutManager.mergeChangedFragments(newBuffer, oldBuffer, clip, &minY, &maxY)
            }
        }

        guard maxY > minY else { return nil }
        return (max(minY, clip.minY), min(maxY, clip.maxY))
    }

    /// Grows `minY`/`maxY` to include the fragment at `fragment`, if it overlaps `clip`.
    ///
    /// Static, with the accumulators passed explicitly rather than captured, and reading the fragment's fields
    /// through the pointer rather than binding the value: this runs once per fragment on every layout pass and
    /// must neither allocate nor retain.
    @inline(__always)
    private static func charge(
        _ fragment: UnsafePointer<VisibleFragment>,
        _ clip: NSRect,
        _ minY: inout CGFloat,
        _ maxY: inout CGFloat
    ) {
        // The fragment's pixels, not just its rect: ink reaching into a neighboring line changes with it.
        let top = fragment.pointee.drawMinY
        let bottom = fragment.pointee.drawMaxY
        guard top < clip.maxY, bottom > clip.minY else { return }
        minY = Swift.min(minY, top)
        maxY = Swift.max(maxY, bottom)
    }

    /// True when drawing `lhs` would produce the same pixels as drawing `rhs`. Typesetting always allocates a fresh
    /// `LineFragment`, so identity plus geometry is enough. Read through pointers, so the merge never copies a
    /// fragment value.
    @inline(__always)
    private static func matches(
        _ lhs: UnsafePointer<VisibleFragment>,
        _ rhs: UnsafePointer<VisibleFragment>
    ) -> Bool {
        lhs.pointee.yPos == rhs.pointee.yPos
            && lhs.pointee.xPos == rhs.pointee.xPos
            && lhs.pointee.width == rhs.pointee.width
            && lhs.pointee.height == rhs.pointee.height
            && lhs.pointee.fragment === rhs.pointee.fragment
    }

    /// Two-pointer merge behind ``changedFragmentBand(in:)``.
    private static func mergeChangedFragments(
        _ newBuffer: UnsafeBufferPointer<VisibleFragment>,
        _ oldBuffer: UnsafeBufferPointer<VisibleFragment>,
        _ clip: NSRect,
        _ minY: inout CGFloat,
        _ maxY: inout CGFloat
    ) {
        let newCount = newBuffer.count
        let oldCount = oldBuffer.count
        // An empty list makes every fragment in the other one a difference; there is nothing to merge.
        guard let newBase = newBuffer.baseAddress, let oldBase = oldBuffer.baseAddress else {
            if let base = newBuffer.baseAddress {
                for index in 0..<newCount { charge(base + index, clip, &minY, &maxY) }
            }
            if let base = oldBuffer.baseAddress {
                for index in 0..<oldCount { charge(base + index, clip, &minY, &maxY) }
            }
            return
        }

        var newIndex = 0
        var oldIndex = 0
        while newIndex < newCount && oldIndex < oldCount {
            let new = newBase + newIndex
            let old = oldBase + oldIndex
            if matches(new, old) {
                newIndex += 1
                oldIndex += 1
            } else if new.pointee.yPos <= old.pointee.yPos {
                charge(new, clip, &minY, &maxY)
                newIndex += 1
            } else {
                charge(old, clip, &minY, &maxY)
                oldIndex += 1
            }
        }
        while newIndex < newCount {
            charge(newBase + newIndex, clip, &minY, &maxY)
            newIndex += 1
        }
        while oldIndex < oldCount {
            charge(oldBase + oldIndex, clip, &minY, &maxY)
            oldIndex += 1
        }
    }
}
