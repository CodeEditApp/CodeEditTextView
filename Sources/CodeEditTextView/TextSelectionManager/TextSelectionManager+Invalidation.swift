//
//  TextSelectionManager+Invalidation.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 2/24/24.
//

import AppKit

extension TextSelectionManager {
    /// Points added to each side of a selection band before it is dirtied.
    ///
    /// Carets and single-fragment selections are thin, and the fill rects and the dirty rect are pixel-aligned
    /// independently of one another. A band that rounded inward would leave a row of stale pixels behind.
    private static let selectionBandPadding: CGFloat = 1

    /// Dirties everywhere the selections painted as of the last invalidation, and everywhere they paint now.
    ///
    /// A selection change is visually local: only the rows the old selection covered and the rows the new one
    /// covers can differ. Dirtying the whole view instead costs a full-viewport repaint on every keystroke,
    /// caret move and click, and subsumes every band the layout manager scopes before it can save a pixel.
    ///
    /// Old geometry comes from the rects recorded by the previous call, never from the previous ranges: stale
    /// pixels sit at the old *rect*, and the layout those ranges were measured against may already be gone.
    /// Text that *moved* between the two calls is covered by the layout pass's own fragment-diff band, and the
    /// ordering holds by construction - ``TextView/layout()`` runs `layoutLines(in:)`, which dirties that band,
    /// before `updateSelectionViews(skipTimerReset:)` reaches this method, and both requests land in the same
    /// display cycle.
    ///
    /// When either side's geometry cannot be resolved, everything the view currently holds is dirtied instead -
    /// with tiles that reaches past the viewport, since tiles keep the pixels of rows that scrolled out of view.
    func setNeedsDisplayForSelections() {
        let previous = lastInvalidatedSelectionRects
        let current = selectionInvalidationRects()
        lastInvalidatedSelectionRects = current

        guard let current, let previous else {
            setNeedsDisplayForDrawnRegion()
            return
        }
        for rect in previous {
            delegate?.setNeedsDisplay(rect)
        }
        for rect in current {
            delegate?.setNeedsDisplay(rect)
        }
    }

    /// Selections with more than this many members stop tracking where they are painted after every layout pass; see
    /// ``layoutPassDidComplete()``.
    private static let trackedSelectionLimit = 64

    /// Rects beyond this many in the record are merged into their bounding rect.
    private static let recordedRectLimit = 32

    /// Adds where the selections are painted after a layout pass to the record of where they were painted.
    ///
    /// A pass that moves text - estimated line heights replaced by real ones above the caret, a width change that
    /// rewraps everything - repaints every fragment it moved, and the selections with them, at their new place. The
    /// record of painted rects has to follow, or the next selection change dirties only where the selections used
    /// to be and leaves the highlight behind at the new place. The old rects stay in the record too: after an edit
    /// they are the only note of pixels the edit stranded (see ``didReplaceCharacters(in:replacementLength:)``).
    func layoutPassDidComplete() {
        guard let recorded = lastInvalidatedSelectionRects else { return }
        guard textSelections.count <= Self.trackedSelectionLimit, let current = selectionInvalidationRects() else {
            // Tracking that many is not worth a pass's time; the next change repaints the view instead.
            lastInvalidatedSelectionRects = nil
            return
        }
        var merged = recorded
        for rect in current where !merged.contains(rect) {
            merged.append(rect)
        }
        if merged.count > Self.recordedRectLimit, let first = merged.first {
            merged = [merged.dropFirst().reduce(first) { $0.union($1) }]
        }
        lastInvalidatedSelectionRects = merged
    }

    /// The bands the current selections paint into, in the text view's coordinate space.
    /// - Returns: The bands, or `nil` if any selection's geometry could not be resolved (no layout manager or
    ///            text view, no layout yet, or a range outside laid-out text).
    private func selectionInvalidationRects() -> [NSRect]? {
        guard let layoutManager, let textView else { return nil }
        let bounds = textView.bounds
        var rects: [NSRect] = []
        rects.reserveCapacity(textSelections.count * 2)
        for selection in textSelections {
            let resolved = appendInvalidationRects(
                for: selection,
                layoutManager: layoutManager,
                bounds: bounds,
                into: &rects
            )
            guard resolved else { return nil }
        }
        return rects
    }

    /// Appends the bands a single selection paints into.
    /// - Returns: Whether the selection's geometry could be resolved. A `false` return leaves `rects` in an
    ///            unspecified state; the caller discards it.
    private func appendInvalidationRects(
        for selection: TextSelection,
        layoutManager: TextLayoutManager,
        bounds: NSRect,
        into rects: inout [NSRect]
    ) -> Bool {
        guard let startRect = layoutManager.rectForOffset(selection.range.location) else { return false }
        var minY = startRect.minY
        var maxY = startRect.maxY

        if !selection.range.isEmpty {
            // Fill rects for a wrapped, multi-line selection all sit between the two end fragments, and
            // fragments are y-ordered, so the endpoints bound every rect the selection covers.
            guard let endRect = layoutManager.rectForOffset(selection.range.max) else { return false }
            minY = min(minY, endRect.minY)
            maxY = max(maxY, endRect.maxY)
        }
        rects.append(band(minY: minY, maxY: maxY, bounds: bounds))

        guard selection.range.isEmpty else { return true }

        // A caret also carries the selected-line highlight, which spans the whole line - taller than the
        // caret's own fragment whenever the line wraps. It sits at the line's document y, below any view zones
        // above the line.
        guard let line = layoutManager.textLineForOffset(selection.range.location) else { return false }
        let documentY = layoutManager.lineStorageYToDocumentY(line.yPos, lineIndex: line.index)
        rects.append(band(minY: documentY, maxY: documentY + line.height, bounds: bounds))
        return true
    }

    /// A full-width dirty band spanning `minY..<maxY`, padded on both ends.
    ///
    /// Full width because an end-of-line selection rect extends to the right edge of the text and the line
    /// highlight spans the whole view; the y extent is the only part worth scoping.
    private func band(minY: CGFloat, maxY: CGFloat, bounds: NSRect) -> NSRect {
        let padding = Self.selectionBandPadding
        return NSRect(
            x: bounds.minX,
            y: minY - padding,
            width: bounds.width,
            height: (maxY - minY) + padding * 2
        )
    }

    /// Dirties every pixel the view holds - the only provable coverage when a selection's geometry cannot be
    /// resolved.
    private func setNeedsDisplayForDrawnRegion() {
        // The region of the view the selections draw into: the layout manager's, which is the text view's own unless
        // the selections are drawn somewhere else (a minimap).
        guard let region = layoutManager?.drawnRegion, !region.isEmpty, !region.isInfinite else {
            delegate?.setNeedsDisplay()
            return
        }
        delegate?.setNeedsDisplay(region)
    }
}
