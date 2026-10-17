//
//  TextView+ScrollToVisible.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 6/15/24.
//

import Foundation
import AppKit

extension TextView {
    fileprivate typealias Direction = TextSelectionManager.Direction
    fileprivate typealias TextSelection = TextSelectionManager.TextSelection

    /// Line heights are estimates until a line is typeset, so a scroll target computed from layout can move once the
    /// destination viewport is laid out. Each pass scrolls, lays out the new viewport, and re-derives the target rect
    /// until it's stable. Bounded to guarantee termination if line heights oscillate.
    private static let maxScrollStabilizationPasses = 8

    /// Scrolls the upmost selection to the visible rect if `scrollView` is not `nil`.
    ///
    /// The selection's line fragment is brought just inside the unobscured viewport (below the host's chrome) with
    /// the smallest scroll that reveals it, so moving the caret past an edge - holding an arrow key, say - keeps its
    /// line pinned at that edge while the text slides under it. The clip view is scrolled directly rather than
    /// through `scrollToVisible(_:)`: AppKit may animate that scroll, leaving the caret and line highlight a line
    /// ahead of the text until the animation catches up, and it doesn't account for the content insets.
    public func scrollSelectionToVisible() {
        guard let scrollView, let selection = getSelection() else {
            return
        }
        let offset = offsetNotPivot(selection)

        // The frame is resized lazily on layout passes. After an edit that grows the document, the frame may not
        // include the target rect yet, and the clip view can't scroll past the document's current bounds. Resize
        // first so the scroll target is reachable.
        updateFrameIfNeeded()

        let clipView = scrollView.contentView
        var remainingPasses = Self.maxScrollStabilizationPasses
        while remainingPasses > 0, let rect = layoutManager.rectForOffset(offset) {
            remainingPasses -= 1
            let origin = scrollOrigin(revealing: rect, in: scrollView)
            guard origin != clipView.bounds.origin else { break }
            clipView.scroll(to: origin)
            scrollView.reflectScrolledClipView(clipView)
            layoutManager.layoutLines()
            selectionManager.updateSelectionViews()
        }
    }

    /// The clip view bounds origin that brings `rect` (in this view's coordinates) inside the region not covered by
    /// the host's chrome with the least movement, or the current origin if it's already there. Content inset padding
    /// isn't chrome: a line scrolled to an edge goes right up against the chrome, over the padding.
    ///
    /// The rect is snapped to whole points the way the line highlight is drawn (see
    /// ``TextSelectionManager/drawSelections(in:)``), so a line pinned to an edge leaves no sliver between its
    /// highlight and the chrome, whatever fraction of a point its height has.
    private func scrollOrigin(revealing rect: CGRect, in scrollView: NSScrollView) -> CGPoint {
        let clipView = scrollView.contentView
        let bounds = clipView.bounds
        let insets = obscuringInsets(of: scrollView)
        let target = convert(rect.pixelAligned, to: clipView)
        var origin = bounds.origin

        // The far edge first, then the near one: a target taller than the viewport keeps its top (leading) edge in
        // view rather than flipping between the two on successive passes.
        if target.maxY > bounds.maxY - insets.bottom {
            origin.y = target.maxY - bounds.height + insets.bottom
        }
        if target.minY < origin.y + insets.top {
            origin.y = target.minY - insets.top
        }
        if target.maxX > bounds.maxX - insets.right {
            origin.x = target.maxX - bounds.width + insets.right
        }
        if target.minX < origin.x + insets.left {
            origin.x = target.minX - insets.left
        }

        guard origin != bounds.origin else { return origin }
        var proposed = bounds
        proposed.origin = origin
        return clipView.constrainBoundsRect(proposed).origin
    }

    /// Scrolls the view to the specified range.
    ///
    /// - Parameters:
    ///   - range: The range to scroll to.
    ///   - center: A flag that determines if the range should be centered in the view. Defaults to `true`.
    ///
    /// If `center` is `true`, the range will be centered in the visible area.
    /// If `center` is `false`, the range will be aligned at the top-left of the view.
    public func scrollToRange(_ range: NSRange, center: Bool = true) {
        guard let scrollView else { return }

        // See `scrollSelectionToVisible()`: after an edit that grows the document the frame may be stale, and the
        // clip view clamps scrolls to it - the first pass would land short and the loop can exit before the
        // frame catches up. Resize first so the target is reachable.
        updateFrameIfNeeded()

        guard var targetRect = layoutManager.rectForOffset(range.location) else { return }

        // An already-visible target only short-circuits when not centering; centering always repositions.
        // Measured against the unobscured rect - a range hidden under the host's chrome is on screen but not
        // readable, so it still needs scrolling.
        if !center && unobscuredVisibleRect.contains(targetRect) {
            return
        }

        let clipView = scrollView.contentView
        var lastRect: CGRect = .zero
        var remainingPasses = Self.maxScrollStabilizationPasses
        while remainingPasses > 0, lastRect != targetRect {
            remainingPasses -= 1
            lastRect = targetRect

            let unobscured = unobscuredVisibleRect
            var origin = if center {
                // Centered in the region the user can actually read, not in the full clip view (part of which
                // sits under the host's chrome).
                CGPoint(
                    x: targetRect.midX - (unobscured.width / 2),
                    y: targetRect.midY - (unobscured.height / 2)
                )
            } else {
                targetRect.origin
            }
            // `scroll(to:)` sets the clip's bounds origin verbatim without constraining it, and document (0, 0) sits
            // at a bounds origin of (-contentInsets.left, -contentInsets.top).
            origin.x -= scrollView.contentInsets.left
            origin.y -= scrollView.contentInsets.top
            var proposedBounds = clipView.bounds
            proposedBounds.origin = origin
            clipView.scroll(to: clipView.constrainBoundsRect(proposedBounds).origin)
            scrollView.reflectScrolledClipView(clipView)

            layoutManager.layoutLines()
            selectionManager.updateSelectionViews()

            guard let newRect = layoutManager.rectForOffset(range.location) else { return }
            targetRect = newRect
        }
    }

    /// Get the selection that should be scrolled to visible for the current text selection.
    /// - Returns: The the selection to scroll to.
    private func getSelection() -> TextSelection? {
        selectionManager
            .textSelections
            .sorted(by: { $0.range.max > $1.range.max }) // Get the lowest one.
            .first
    }

    /// Returns the offset that isn't the pivot of the selection.
    /// - Parameter selection: The selection to use.
    /// - Returns: The offset suitable for scrolling to.
    private func offsetNotPivot(_ selection: TextSelection) -> Int {
        guard let pivot = selection.pivot else {
            return selection.range.location
        }
        if selection.range.location == pivot {
            return selection.range.max
        } else {
            return selection.range.location
        }
    }
}
