//
//  TextLayoutManager+FragmentBuffer.swift
//  CodeEditTextView
//
//  Created by Abe Malla on 4/19/26.
//

import AppKit

extension TextLayoutManager {
    // MARK: - Fragment Buffer Capacity

    /// Passes a small working set must survive before capacity is reclaimed, the multiple of the live fragment
    /// count kept when it is, and the floor below which reclaiming saves only kilobytes.
    static let fragmentBufferShrinkRun: Int = 30
    static let fragmentBufferHeadroom: Int = 4
    static let minFragmentBufferCapacity: Int = 256

    /// Raises the buffer a pass is about to fill to the capacity the other one already holds.
    ///
    /// The two buffers exchange roles every pass, so a capacity one of them grew alone belongs to whichever
    /// role it happens to be playing: each buffer's capacity would then alternate between the two values every
    /// pass, and any pass whose working set sat between them would reallocate. Levelling costs one allocation
    /// the first time a pass grows a buffer and is a no-op afterwards - `reserveCapacity` does not reallocate a
    /// uniquely-referenced buffer that is already large enough - and
    /// ``reclaimFragmentBufferCapacity(liveCount:)`` brings the levelled pair back down together.
    func levelFragmentBufferCapacity() {
        guard visibleFragments.capacity < previousVisibleFragments.capacity else { return }
        visibleFragments.reserveCapacity(previousVisibleFragments.capacity)
    }

    /// Hands back fragment-buffer capacity retained from a pass much larger than the current working set.
    ///
    /// Both buffers are reused across passes (`swap` + `removeAll(keepingCapacity:)`), so a single oversized
    /// pass - a tall transient window, a wide `invalidateLayoutForRect` - otherwise pins its high-water
    /// capacity on both of them for the lifetime of the view. Reclaiming requires a run of small passes and
    /// only fires above *twice* the retained multiple: that gap is wider than any pass the shrink enables, so
    /// shrinking can never set up the regrowth that would undo it. A steady-state pass reads two capacities
    /// and a counter here and allocates nothing.
    func reclaimFragmentBufferCapacity(liveCount: Int) {
        let target = max(liveCount * Self.fragmentBufferHeadroom, Self.minFragmentBufferCapacity)
        guard max(visibleFragments.capacity, previousVisibleFragments.capacity) > target * 2 else {
            smallFragmentPassRun = 0
            return
        }
        smallFragmentPassRun += 1
        guard smallFragmentPassRun >= Self.fragmentBufferShrinkRun else { return }
        smallFragmentPassRun = 0

        var compacted = ContiguousArray<VisibleFragment>()
        compacted.reserveCapacity(target)
        compacted.append(contentsOf: visibleFragments)
        visibleFragments = compacted
        // Only this buffer's capacity outlives the call: the next pass swaps it into `visibleFragments` and
        // clears it, and this pass's redraw decision has already read its contents.
        previousVisibleFragments = ContiguousArray()
        previousVisibleFragments.reserveCapacity(target)
    }
}
