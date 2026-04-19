//
//  ViewZoneManager.swift
//  CodeEditTextView
//
//  Created by Abe Malla on 4/12/26.
//

import AppKit

/// Manages view zones — horizontal bands of space inserted between lines of text.
///
/// The manager maintains a sorted array of ``ViewZone`` entries and computes prefix sums of their heights
/// for O(log n) position lookups. This is modeled after VSCode's `LinesLayout` whitespace system.
///
/// ## Usage
///
/// ```swift
/// let zoneID = viewZoneManager.addZone(ViewZone(afterLineNumber: 5, heightInPoints: 30, view: myButton))
/// // Later:
/// viewZoneManager.removeZone(id: zoneID)
/// ```
///
/// ## Layout Integration
///
/// The ``TextLayoutManager`` queries the view zone manager during layout to:
/// 1. Compute the extra vertical offset for lines due to view zones above them.
/// 2. Position zone views between lines during the layout pass.
/// 3. Adjust content height to include all view zone heights.
///
/// ## Performance
///
/// - Zone lookup by line: O(log n) via binary search
/// - Prefix sum recomputation: O(n) but only when zones change (lazy invalidation)
/// - Zone iteration for a viewport: O(k) where k is the number of zones in the viewport
public final class ViewZoneManager {
    // MARK: - Storage

    /// All zones, sorted by `(afterLineNumber, ordinal)`. Kept sorted on mutation.
    public private(set) var zones: [ViewZone] = []

    /// Prefix sums of zone heights. `prefixSums[i]` is the cumulative height of zones `0..<i+1`.
    private var prefixSums: [CGFloat] = []

    /// Index up to which `prefixSums` is valid. Lazy invalidation: only recompute from this index forward.
    private var prefixSumValidIndex: Int = -1

    /// Total height of all view zones. Updated lazily.
    public var totalHeight: CGFloat {
        if zones.isEmpty { return 0 }
        ensurePrefixSums()
        return prefixSums.last ?? 0
    }

    /// The callback invoked when zones change, so the layout manager can trigger a re-layout.
    var onZonesChanged: (() -> Void)?

    // MARK: - Public API

    /// Adds a view zone. Returns the zone's ID for later removal or update.
    @discardableResult
    public func addZone(_ zone: ViewZone) -> UUID {
        let insertIndex = insertionIndex(for: zone)
        zones.insert(zone, at: insertIndex)
        invalidatePrefixSums(from: insertIndex)
        onZonesChanged?()
        return zone.id
    }

    /// Removes a view zone by its ID. No-op if the ID is not found.
    public func removeZone(id: UUID) {
        guard let index = zones.firstIndex(where: { $0.id == id }) else { return }
        if let view = zones[index].view {
            view.removeFromSuperview()
        }
        zones.remove(at: index)
        invalidatePrefixSums(from: index)
        onZonesChanged?()
    }

    /// Updates the height of a zone. Triggers re-layout.
    public func updateZoneHeight(id: UUID, newHeight: CGFloat) {
        guard let index = zones.firstIndex(where: { $0.id == id }) else { return }
        zones[index].heightInPoints = newHeight
        invalidatePrefixSums(from: index)
        onZonesChanged?()
    }

    /// Updates the line number a zone appears after. Triggers re-layout.
    /// The zone is re-sorted to maintain order.
    public func updateZoneLineNumber(id: UUID, newLineNumber: Int) {
        guard let index = zones.firstIndex(where: { $0.id == id }) else { return }
        var zone = zones[index]
        zone.afterLineNumber = newLineNumber
        zones.remove(at: index)
        let newIndex = insertionIndex(for: zone)
        zones.insert(zone, at: newIndex)
        invalidatePrefixSums(from: min(index, newIndex))
        onZonesChanged?()
    }

    /// Removes all view zones.
    public func removeAll() {
        for zone in zones {
            zone.view?.removeFromSuperview()
        }
        zones.removeAll()
        prefixSums.removeAll()
        prefixSumValidIndex = -1
        onZonesChanged?()
    }

    // MARK: - Layout Queries

    /// Returns the cumulative height of all view zones that appear after lines `<= lineNumber`.
    /// In other words, the extra vertical space above line `lineNumber + 1` due to view zones.
    ///
    /// - Parameter lineNumber: The line number (0-indexed).
    /// - Returns: The total whitespace height inserted at or before this line.
    public func whitespaceHeightBeforeLine(_ lineNumber: Int) -> CGFloat {
        guard !zones.isEmpty else { return 0 }
        ensurePrefixSums()

        let searchLine = lineNumber
        var lo = 0
        var hi = zones.count - 1
        var result = -1
        while lo <= hi {
            let mid = lo + (hi - lo) / 2
            if zones[mid].afterLineNumber < searchLine {
                result = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }

        if result < 0 { return 0 }
        return prefixSums[result]
    }

    /// Returns all view zones that are visible in the given y-position range, accounting for line positions.
    ///
    /// - Parameters:
    ///   - minY: The minimum y position (in document coordinates).
    ///   - maxY: The maximum y position (in document coordinates).
    ///   - lineYPosition: A closure that returns the y position of a given line index (0-based). The y position
    ///     should be the position *without* view zone offsets (raw line position from the line storage).
    /// - Returns: An array of tuples containing the zone, its computed y position, and its index in the zones array.
    public func zonesInViewport(
        minY: CGFloat,
        maxY: CGFloat,
        lineYPosition: (Int) -> CGFloat?
    ) -> [(zone: ViewZone, yPosition: CGFloat, index: Int)] {
        guard !zones.isEmpty else { return [] }
        ensurePrefixSums()

        var result: [(zone: ViewZone, yPosition: CGFloat, index: Int)] = []

        for (index, zone) in zones.enumerated() {
            // The zone's y-position is after the line it follows, plus the whitespace of all prior zones.
            let lineEndY: CGFloat
            if zone.afterLineNumber <= 0 {
                lineEndY = 0
            } else if let lineY = lineYPosition(zone.afterLineNumber - 1) {
                lineEndY = lineY
            } else {
                continue
            }

            let priorWhitespace: CGFloat = index > 0 ? prefixSums[index - 1] : 0
            let zoneY = lineEndY + priorWhitespace

            if zoneY + zone.heightInPoints < minY { continue }
            if zoneY > maxY { break }

            result.append((zone: zone, yPosition: zoneY, index: index))
        }

        return result
    }

    /// Returns all view zones after a given line number.
    /// - Parameter lineNumber: The line number to query zones after.
    /// - Returns: Zones that appear after the given line number.
    public func zones(afterLine lineNumber: Int) -> [ViewZone] {
        guard !zones.isEmpty else { return [] }

        var lo = 0
        var hi = zones.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if zones[mid].afterLineNumber < lineNumber {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        var result: [ViewZone] = []
        while lo < zones.count && zones[lo].afterLineNumber == lineNumber {
            result.append(zones[lo])
            lo += 1
        }
        return result
    }

    /// Adjusts zone line numbers after a text edit.
    ///
    /// When lines are inserted or deleted, zones after the edit point need their `afterLineNumber` updated.
    ///
    /// - Parameters:
    ///   - afterLine: The line number after which the edit occurred.
    ///   - delta: The number of lines inserted (positive) or deleted (negative).
    public func adjustLineNumbers(afterLine: Int, delta: Int) {
        guard delta != 0 else { return }
        var didChange = false
        for index in 0..<zones.count {
            if zones[index].afterLineNumber > afterLine {
                zones[index].afterLineNumber = max(0, zones[index].afterLineNumber + delta)
                didChange = true
            }
        }
        if didChange {
            // Re-sort in case adjustments changed ordering
            zones.sort { ($0.afterLineNumber, $0.ordinal) < ($1.afterLineNumber, $1.ordinal) }
            invalidatePrefixSums(from: 0)
        }
    }

    // MARK: - Private

    /// Returns the insertion index to maintain sort order for the given zone.
    private func insertionIndex(for zone: ViewZone) -> Int {
        var lo = 0
        var hi = zones.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            let existing = zones[mid]
            if (existing.afterLineNumber, existing.ordinal) < (zone.afterLineNumber, zone.ordinal) {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }

    /// Invalidates prefix sums from the given index onward.
    private func invalidatePrefixSums(from index: Int) {
        prefixSumValidIndex = min(prefixSumValidIndex, index - 1)
    }

    /// Ensures prefix sums are fully computed up to the end of the zones array.
    private func ensurePrefixSums() {
        guard !zones.isEmpty else { return }

        if prefixSums.count != zones.count {
            prefixSums = Array(repeating: 0, count: zones.count)
            prefixSumValidIndex = -1
        }

        let startIndex = prefixSumValidIndex + 1
        guard startIndex < zones.count else { return }

        for i in startIndex..<zones.count {
            let previousSum: CGFloat = i > 0 ? prefixSums[i - 1] : 0
            prefixSums[i] = previousSum + zones[i].heightInPoints
        }
        prefixSumValidIndex = zones.count - 1
    }
}
