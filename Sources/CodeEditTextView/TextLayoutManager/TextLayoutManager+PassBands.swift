//
//  TextLayoutManager+PassBands.swift
//  CodeEditTextView
//
//  The shape of a single layout pass: the y-bands it walks - the region it must cover, and, when a caller asked
//  for a band the viewport's own pass cannot absorb, the second one it still owes that caller - and the state
//  threaded through the walk.
//

import AppKit

extension TextLayoutManager {
    /// A padded y-range a layout pass walks.
    struct LayoutBand {
        var minY: CGFloat
        var maxY: CGFloat
    }

    /// The bands one pass walks: the band around its rect and, when it owes a caller a detached band, that one.
    typealias LayoutPassBands = (first: LayoutBand, second: LayoutBand?)

    /// Mutable state threaded through the layout pass. Kept as an inout struct so the outer `layoutLines(in:)`
    /// stays short enough for SwiftLint and so extracted helpers can see/update the same counters without tuple
    /// returns.
    struct LayoutPassContext {
        /// The band being walked. Mutable so a pass that owes a caller a second, detached band can re-point the
        /// walk at it without rebuilding the accumulated state.
        var minY: CGFloat
        var maxY: CGFloat
        let forceLayout: Bool
        let hasViewZones: Bool
        var maxFoundLineWidth: CGFloat
        let textStorage: NSTextStorage
        /// Snapshot of `maxLineLayoutWidth` taken once at the top of the pass so we don't repeatedly bounce
        /// through the delegate's `textViewportSize().width` witness-table call per line.
        let cachedMaxLineLayoutWidth: CGFloat
        /// This pass's generation, stamped on every line it walks.
        let passGeneration: UInt32
        /// The generation of the previous completed pass; 0 when every line counts as not visible.
        let previousPassGeneration: UInt32

        var usedZoneIDs = Set<UUID>()
        var yContentAdjustment: CGFloat = 0
        /// Lines this pass typeset; ``TextLayoutManager/layoutLines(in:)`` returns them. Grows only with typesetting
        /// work, so a pass that reuses every line's fragments never allocates it.
        var laidOutLines: Set<TextLine.ID> = []
    }

    /// The bands a pass over `pass` must walk to also satisfy `request`, in document order.
    ///
    /// ``layoutPassRects(for:)`` prefers the viewport whenever a union with the request would have to fabricate
    /// coverage over the gap between them, which leaves the request itself unlaid - and `layoutLines(in:)` is
    /// the public way to typeset a range, so a caller that asked for a band and silently got nothing has no way
    /// to tell. That request comes back here as a second band instead: two walks, no gap.
    ///
    /// The two are merged when the padding every pass adds already closes the distance between them. A line
    /// walked by both bands would append its fragments to `visibleFragments` twice, which the fragment diff
    /// reads as a change and `drawVisibleFragments` renders twice.
    func layoutPassBands(pass: NSRect, request: NSRect) -> LayoutPassBands {
        let padded = paddedBand(pass)
        guard let detached = detachedRequest(request, pass: pass) else { return (padded, nil) }

        let detachedBand = paddedBand(detached)
        guard detachedBand.minY > padded.maxY || detachedBand.maxY < padded.minY else {
            return (LayoutBand(minY: min(padded.minY, detachedBand.minY),
                               maxY: max(padded.maxY, detachedBand.maxY)), nil)
        }
        return detachedBand.maxY < padded.minY ? (detachedBand, padded) : (padded, detachedBand)
    }

    /// The request, when the pass rect does not already cover its y-extent.
    ///
    /// An unbounded request carries no information about what to lay out (see ``layoutPassRects(for:)``) and is
    /// never owed a band of its own.
    private func detachedRequest(_ request: NSRect, pass: NSRect) -> NSRect? {
        guard !Self.isUnbounded(request), request.height > 0 else { return nil }
        guard request.minY < pass.minY || request.maxY > pass.maxY else { return nil }
        return request
    }

    /// `rect`'s y-extent grown by ``verticalLayoutPadding`` on both ends and clamped at the top of the document.
    private func paddedBand(_ rect: NSRect) -> LayoutBand {
        LayoutBand(
            minY: max(rect.minY - verticalLayoutPadding, 0),
            maxY: max(rect.maxY + verticalLayoutPadding, 0)
        )
    }
}
