//
//  LineDecorationManager.swift
//  CodeEditTextView
//
//  Created by Abe Malla on 4/12/26.
//

import AppKit

/// Manages line decorations for the text view.
///
/// Provides O(log n) lookup of decorations by line number using a sorted structure.
/// Decorations are grouped by line for efficient rendering during the layout pass.
///
/// Modeled after VSCode's `EditorDecorations` and `DecorationsOverviewRuler`.
public final class LineDecorationManager {
    /// Callback invoked when decorations change. Set by the layout manager to trigger relayout.
    public var onDecorationsChanged: (() -> Void)?

    /// All decorations, keyed by ID for O(1) removal.
    private var decorationsById: [UUID: LineDecoration] = [:]

    /// Cached sorted array of decorations, sorted by lineRange.lowerBound for binary search.
    /// Invalidated and rebuilt lazily.
    private var sortedDecorations: [LineDecoration]?

    /// The number of managed decorations.
    public var count: Int { decorationsById.count }

    public init() {}

    // MARK: - Mutation

    /// Add a decoration and return its ID.
    @discardableResult
    public func addDecoration(_ decoration: LineDecoration) -> UUID {
        decorationsById[decoration.id] = decoration
        invalidateCache()
        onDecorationsChanged?()
        return decoration.id
    }

    /// Remove a decoration by ID.
    public func removeDecoration(id: UUID) {
        guard decorationsById.removeValue(forKey: id) != nil else { return }
        invalidateCache()
        onDecorationsChanged?()
    }

    /// Remove all decorations with a given group tag.
    public func removeDecorations(group: String) {
        let idsToRemove = decorationsById.values.filter { $0.group == group }.map(\.id)
        guard !idsToRemove.isEmpty else { return }
        for id in idsToRemove {
            decorationsById.removeValue(forKey: id)
        }
        invalidateCache()
        onDecorationsChanged?()
    }

    /// Remove all decorations.
    public func removeAllDecorations() {
        guard !decorationsById.isEmpty else { return }
        decorationsById.removeAll()
        invalidateCache()
        onDecorationsChanged?()
    }

    /// Update the line range of an existing decoration.
    public func updateDecorationRange(id: UUID, lineRange: ClosedRange<Int>) {
        guard decorationsById[id] != nil else { return }
        decorationsById[id]!.lineRange = lineRange
        invalidateCache()
        onDecorationsChanged?()
    }

    /// Update the style of an existing decoration.
    public func updateDecorationStyle(id: UUID, style: LineDecoration.Style) {
        guard decorationsById[id] != nil else { return }
        decorationsById[id]!.style = style
        invalidateCache()
        onDecorationsChanged?()
    }

    // MARK: - Query

    /// Returns all decorations that overlap with the given line range.
    /// Uses binary search for the starting position, then scans forward.
    public func decorations(inLineRange range: ClosedRange<Int>) -> [LineDecoration] {
        let sorted = ensureSorted()
        guard !sorted.isEmpty else { return [] }

        // Binary search: find first decoration whose lineRange.upperBound >= range.lowerBound
        var lo = 0
        var hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid].lineRange.upperBound < range.lowerBound {
                lo = mid + 1
            } else {
                hi = mid
            }
        }

        var result: [LineDecoration] = []
        for idx in lo..<sorted.count {
            let dec = sorted[idx]
            // Once the decoration starts past our range, stop
            if dec.lineRange.lowerBound > range.upperBound {
                break
            }
            // Check overlap
            if dec.lineRange.overlaps(range) {
                result.append(dec)
            }
        }
        return result
    }

    /// Returns all decorations that affect a single line index.
    public func decorations(forLine line: Int) -> [LineDecoration] {
        decorations(inLineRange: line...line)
    }

    /// Returns all decorations.
    public func allDecorations() -> [LineDecoration] {
        Array(decorationsById.values)
    }

    // MARK: - Edit Tracking

    /// Adjusts decoration line ranges after a text edit.
    ///
    /// - Parameters:
    ///   - editLineStart: The first line affected by the edit (0-based).
    ///   - oldLineCount: The number of lines that were in the edited range before the edit.
    ///   - newLineCount: The number of lines now in the edited range after the edit.
    public func adjustForEdit(editLineStart: Int, oldLineCount: Int, newLineCount: Int) {
        let delta = newLineCount - oldLineCount
        guard delta != 0 else { return }

        let editLineEnd = editLineStart + oldLineCount - 1
        var changed = false
        var idsToRemove: [UUID] = []

        for (id, var decoration) in decorationsById {
            let lower = decoration.lineRange.lowerBound
            let upper = decoration.lineRange.upperBound

            if upper < editLineStart {
                // Decoration entirely before the edit — unaffected
                continue
            } else if lower > editLineEnd {
                // Decoration entirely after the edit — shift by delta
                decoration.lineRange = (lower + delta)...(upper + delta)
                decorationsById[id] = decoration
                changed = true
            } else {
                // Decoration overlaps the edit region
                if delta < 0 {
                    // Lines were deleted
                    let newLower = min(lower, editLineStart)
                    let newUpper = max(upper + delta, editLineStart + newLineCount - 1)
                    if newUpper < newLower {
                        // Decoration range collapsed entirely — remove
                        idsToRemove.append(id)
                    } else {
                        decoration.lineRange = newLower...newUpper
                        decorationsById[id] = decoration
                    }
                    changed = true
                } else {
                    // Lines were inserted — expand or shift based on stickiness
                    switch decoration.stickiness {
                    case .neverGrowsWhenTypingAtEdges:
                        if lower >= editLineStart && upper <= editLineEnd {
                            // Entirely within — shift
                            decoration.lineRange = lower...(upper + delta)
                        }
                    case .growsOnlyWhenTypingAfter:
                        let newUpper = upper + delta
                        decoration.lineRange = lower...newUpper
                    case .alwaysGrowsWhenTypingAtEdges:
                        let newUpper = upper + delta
                        decoration.lineRange = lower...newUpper
                    }
                    decorationsById[id] = decoration
                    changed = true
                }
            }
        }

        for id in idsToRemove {
            decorationsById.removeValue(forKey: id)
        }

        if changed {
            invalidateCache()
        }
    }

    // MARK: - Private

    private func invalidateCache() {
        sortedDecorations = nil
    }

    private func ensureSorted() -> [LineDecoration] {
        if let cached = sortedDecorations {
            return cached
        }
        let sorted = decorationsById.values.sorted { $0.lineRange.lowerBound < $1.lineRange.lowerBound }
        sortedDecorations = sorted
        return sorted
    }
}
