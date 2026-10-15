//
//  TextLayoutManager+Layout.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 4/7/25.
//

import AppKit

extension TextLayoutManager {
    /// Contains all data required to perform layout on a text line.
    private struct LineLayoutData {
        let minY: CGFloat
        let maxY: CGFloat
        let maxWidth: CGFloat
    }

    // MARK: - Layout Lines

    /// Lays out all visible lines.
    ///
    /// ## Overview
    ///
    /// Walks the lines overlapping the viewport (plus vertical padding), triggers per-line typesetting only when the
    /// line was not previously laid out for the current width / was previously off-screen / has not been fully broken
    /// into fragments, and collects every visible fragment into `visibleFragments` for the subsequent draw pass.
    ///
    /// Unlike the previous architecture this method does **not** mutate the view tree - there are no per-fragment
    /// `NSView`s to insert/remove. The only subviews this method touches are *view zones* (opaque host views the caller
    /// supplies) and the output is a flat y-ordered list of `VisibleFragment` records. After layout we dirty
    /// `layoutView` so `draw(_:)` renders the new fragments.
    ///
    /// ## Reentry
    ///
    /// Layout is *not* reentrant - entering `layoutLines()` while a pass is already running corrupts `visibleFragments`
    /// and produces lost-update bugs. Calls made while a transaction is open (``isInTransaction``) or while another
    /// pass holds `layoutLock` are skipped, and a follow-up pass is scheduled on the layout view.
    ///
    /// - Returns: The IDs of the lines this pass typeset (lines whose existing fragments were reused are not
    ///   included); empty when the pass was skipped. The same in every build configuration.
    @discardableResult
    public func layoutLines(in rect: NSRect? = nil) -> Set<TextLine.ID> {
        // Rect-less passes use the delegate's preferred layout rect, which includes any responsive-scrolling
        // prepared band - laying out only `visibleRect` here would drop the band's fragments and the follow-up
        // draw would erase already-rendered band pixels AppKit still considers valid. The requested rect is
        // then grown to cover the live viewport so a pass can never shrink on-screen fragment coverage.
        guard let requestedRect = rect ?? delegate?.preferredLayoutRect,
              let textStorage else {
            return []
        }
        finishAttributeFixingIfEditedBeforeLayout()
        let (visibleRect, viewport) = layoutPassRects(for: requestedRect)

        guard !isInTransaction, layoutLock.try() else {
            // Mid-transaction, or re-entered from client code a running pass called out to. Skip and schedule a
            // follow-up pass instead of laying out half-applied state or deadlocking the non-recursive lock.
            layoutView?.needsLayout = true
            // The fragment lists are mid-flight, but the viewport may have moved, and rows a scroll just revealed
            // must still get pixels. The fragments covering them already exist inside the padded band the last
            // completed pass laid out. With tiles, cover the viewport now (new tiles are entirely dirty); the
            // follow-up pass's fragment diff then repaints whatever it changes in them. Without tiles, the record
            // of committed pixels decides what to dirty. Both only ever dirty more, never less, and take no lock.
            if let tiles = activeTileManager {
                _ = tiles.updateCoverage(viewport: viewport, pass: visibleRect, bands: lastPassBands)
                updateTileFollowerCoverage(viewport: viewport, pass: visibleRect)
            } else if !viewport.isEmpty {
                retainRasterized(within: viewport)
                setNeedsDisplayForUnrasterized(viewport: viewport)
            }
            return []
        }

        // Forced passes follow config/attribute changes; drop the cached line height estimate so empty lines and
        // estimate-based fallbacks pick up the current typing attributes.
        if needsLayout {
            _estimateLineHeight = nil
        }

        let bands = layoutPassBands(pass: visibleRect, request: requestedRect)
        let hasViewZones = !viewZones.zones.isEmpty

        // Reset the visible fragment list for this pass, keeping the previous pass's list for change detection.
        // Swapping (not copying) reuses both buffers so we don't thrash the allocator between passes.
        swap(&visibleFragments, &previousVisibleFragments)
        visibleFragments.removeAll(keepingCapacity: true)
        levelFragmentBufferCapacity()

        var ctx = LayoutPassContext(
            minY: bands.first.minY,
            maxY: bands.first.maxY,
            forceLayout: needsLayout,
            hasViewZones: hasViewZones,
            maxFoundLineWidth: maxLineWidth,
            textStorage: textStorage,
            cachedMaxLineLayoutWidth: maxLineLayoutWidth,
            passGeneration: nextPassGeneration(),
            previousPassGeneration: lastCompletedPassGeneration
        )

        walkBands(bands, ctx: &ctx)
        measureVisibleInkOverflow()

        if hasViewZones {
            layoutVisibleZones(ctx: &ctx)
            // Remove view zone views that are no longer in the viewport.
            for zone in viewZones.zones where !ctx.usedZoneIDs.contains(zone.id) {
                zone.view?.removeFromSuperview()
            }
        }

        // The lines this pass stamped are now the visible set.
        lastCompletedPassGeneration = ctx.passGeneration
        lastPassBands = bands

        // The delegate methods below may call another layout pass, make sure we don't send it into a loop of forced
        // layout.
        needsLayout = false

        layoutLock.unlock()

        applyRedrawDecision(forceLayout: ctx.forceLayout, viewport: viewport, pass: visibleRect, bands: bands)
        if let textView = layoutView as? TextView {
            textView.layoutPassDidComplete()
        } else {
            layoutTiles?.layoutPassDidComplete()
        }

        reclaimFragmentBufferCapacity(liveCount: visibleFragments.count)

        notifyDelegateAfterPass(ctx: ctx)

        return ctx.laidOutLines
    }

    /// Records the furthest any visible fragment paints past its rect, for ``drawVisibleFragments(in:)``.
    private func measureVisibleInkOverflow() {
        var above: CGFloat = 0
        var below: CGFloat = 0
        visibleFragments.withUnsafeBufferPointer { fragments in
            for fragment in fragments {
                above = max(above, fragment.yPos - fragment.drawMinY)
                below = max(below, fragment.drawMaxY - fragment.yPos - fragment.height)
            }
        }
        visibleInkOverflow = (above, below)
    }

    /// Sends post-pass notifications for width, y-adjustment, and height changes. Called outside `layoutLock` -
    /// each delegate method may synchronously trigger another layout pass.
    private func notifyDelegateAfterPass(ctx: LayoutPassContext) {
        if ctx.maxFoundLineWidth > maxLineWidth {
            maxLineWidth = ctx.maxFoundLineWidth
        }

        if ctx.yContentAdjustment != 0 {
            delegate?.layoutManagerYAdjustment(ctx.yContentAdjustment)
        }

        // Compare against the height last reported to the delegate, not the view's frame - the frame intentionally
        // includes overscroll, so a frame comparison reports (and re-runs frame/selection updates) on every pass.
        let contentHeight = lineStorage.height + viewZones.totalHeight
        if contentHeight != lastReportedContentHeight {
            lastReportedContentHeight = contentHeight
            delegate?.layoutManagerHeightDidUpdate(newHeight: contentHeight)
        }
    }

    /// Walks the pass's bands, in document order, and leaves `ctx` on the primary one - which is what the
    /// view-zone pass and the delegate notifications downstream read.
    ///
    /// A second band exists only when a caller asked for a region the viewport's own pass could not absorb (see
    /// ``layoutPassBands(pass:request:)``). The two are disjoint by construction, so no fragment is appended
    /// twice, but the second may sit *above* the first and `visibleFragments` has to stay in document order for
    /// the fragment diff's two-pointer merge to mean anything.
    private func walkBands(_ bands: (first: LayoutBand, second: LayoutBand?), ctx: inout LayoutPassContext) {
        iterateLines(ctx: &ctx)
        guard let second = bands.second else { return }
        ctx.minY = second.minY
        ctx.maxY = second.maxY
        iterateLines(ctx: &ctx)
        ctx.minY = bands.first.minY
        ctx.maxY = bands.first.maxY
        if second.maxY <= bands.first.minY {
            visibleFragments.sort { $0.yPos < $1.yPos }
        }
    }

    private func iterateLines(ctx: inout LayoutPassContext) {
        // When view zones exist, line storage Y positions don't include whitespace. Subtract total whitespace from minY
        // for a conservative lower bound; keep maxY as-is since line storage Y is always <= document Y.
        let queryMinY = ctx.hasViewZones ? max(ctx.minY - viewZones.totalHeight, 0) : ctx.minY

        for linePosition in linesStartingAt(queryMinY, until: ctx.maxY).lazy {
            let whitespaceOffset = ctx.hasViewZones
                ? viewZones.whitespaceHeightBeforeLine(linePosition.index)
                : 0
            let documentYPos = linePosition.yPos + whitespaceOffset

            guard documentYPos < ctx.maxY else { continue }

            processLine(linePosition, whitespaceOffset: whitespaceOffset, ctx: &ctx)
        }
    }

    /// Positions every view zone whose band intersects the laid-out y range and records it in `usedZoneIDs`.
    ///
    /// Zone layout is driven by the zones themselves rather than by the line following each zone, so zones after
    /// the final line (which have no following line) and zones taller than the vertical layout padding are still
    /// positioned. A zone with `afterLineNumber == k` occupies the whitespace band directly below line index `k` -
    /// the same convention `ViewZoneManager.whitespaceHeightBeforeLine(_:)` uses to shift line positions.
    private func layoutVisibleZones(ctx: inout LayoutPassContext) {
        // `zones` is sorted by (afterLineNumber, ordinal), so zone document y positions are non-decreasing and the
        // loop can stop at the first zone starting past `maxY`. Binary-search the first zone whose band can reach
        // the viewport instead of walking every zone above it - each distinct gap line in the walk costs an
        // O(log n) line-storage lookup, which adds up with thousands of zones above the viewport.
        let zones = viewZones.zones
        let startIndex = firstZoneIndex(reaching: ctx.minY, in: zones)
        guard startIndex < zones.count else { return }
        var gapLine = Int.min
        var zoneY: CGFloat = 0
        for zone in zones[startIndex...] {
            if zone.afterLineNumber != gapLine {
                gapLine = zone.afterLineNumber
                let lineBottom: CGFloat
                if gapLine < 0 {
                    lineBottom = 0
                } else if let linePosition = lineStorage.getLine(atIndex: gapLine) {
                    lineBottom = linePosition.yPos + linePosition.height
                } else {
                    lineBottom = lineStorage.height
                }
                zoneY = lineBottom + viewZones.whitespaceHeightBeforeLine(gapLine)
            }
            if zoneY >= ctx.maxY {
                break
            }
            let zoneMaxY = zoneY + zone.heightInPoints
            if zoneMaxY > ctx.minY {
                layoutViewZone(zone, at: zoneY)
                ctx.usedZoneIDs.insert(zone.id)
            }
            zoneY = zoneMaxY
        }
    }

    /// Advances ``passGeneration`` for a pass that is about to run. Generation 0 is never used: it is the stamp of a
    /// line no pass has walked. When the counter wraps (after 2³² passes), every line's stamp is cleared first, so a
    /// stamp from the previous cycle cannot alias a new generation.
    private func nextPassGeneration() -> UInt32 {
        passGeneration &+= 1
        if passGeneration == 0 {
            // Lines without a `TextLine` yet have no stamp to clear.
            lineStorage.forEachExistingData { line in
                line.visibleStamp = 0
            }
            lastCompletedPassGeneration = 0
            passGeneration = 1
        }
        return passGeneration
    }

    /// Decides whether a line needs typesetting or can just re-use its existing fragments, dispatches accordingly, and
    /// tracks it as visible.
    private func processLine(
        _ linePosition: TextLineStorage<TextLine>.TextLinePosition,
        whitespaceOffset: CGFloat,
        ctx: inout LayoutPassContext
    ) {
        let line = linePosition.data
        let wasNotVisible = ctx.previousPassGeneration == 0 || line.visibleStamp != ctx.previousPassGeneration
        line.visibleStamp = ctx.passGeneration

        let linePositionNeedsLayout = line.needsLayout(maxWidth: ctx.cachedMaxLineLayoutWidth)
        let lineNotEntirelyLaidOut = linePosition.height != linePosition.data.lineFragments.height

        if ctx.forceLayout || linePositionNeedsLayout || wasNotVisible || lineNotEntirelyLaidOut {
            let (yAdjustment, _) = layoutLine(
                linePosition,
                whitespaceOffset: whitespaceOffset,
                textStorage: ctx.textStorage,
                yRange: ctx.minY..<ctx.maxY,
                maxFoundLineWidth: &ctx.maxFoundLineWidth,
                maxLineLayoutWidth: ctx.cachedMaxLineLayoutWidth
            )
            ctx.yContentAdjustment += yAdjustment
            ctx.laidOutLines.insert(linePosition.data.id)
        } else {
            // Line is already laid out - just append its fragments at their current positions.
            appendVisibleFragments(for: linePosition, whitespaceOffset: whitespaceOffset)
        }
    }

    // MARK: - Layout Single Line

    private func layoutLine(
        _ linePosition: TextLineStorage<TextLine>.TextLinePosition,
        whitespaceOffset: CGFloat = 0,
        textStorage: NSTextStorage,
        yRange: Range<CGFloat>,
        maxFoundLineWidth: inout CGFloat,
        maxLineLayoutWidth: CGFloat
    ) -> (CGFloat, wasLineHeightChanged: Bool) {
        let lineSize = typesetAndCollect(
            linePosition,
            whitespaceOffset: whitespaceOffset,
            textStorage: textStorage,
            layoutData: LineLayoutData(minY: yRange.lowerBound, maxY: yRange.upperBound, maxWidth: maxLineLayoutWidth)
        )
        let wasLineHeightChanged = lineSize.height != linePosition.height
        var yContentAdjustment: CGFloat = 0.0

        if wasLineHeightChanged {
            lineStorage.update(
                atOffset: linePosition.range.location,
                delta: 0,
                deltaHeight: lineSize.height - linePosition.height
            )
            // Y positions of subsequent lines just shifted; cached selection rects are now stale.
            layoutRevision &+= 1

            if linePosition.yPos < yRange.lowerBound {
                // Adjust the scroll position by the difference between the new height and old.
                yContentAdjustment += lineSize.height - linePosition.height
            }
        }
        if maxFoundLineWidth < lineSize.width {
            maxFoundLineWidth = lineSize.width
        }

        return (yContentAdjustment, wasLineHeightChanged)
    }

    /// Runs typesetting for the given line and appends each of its fragments to `visibleFragments`.
    /// - Returns: The total laid-out width and height of the line.
    private func typesetAndCollect(
        _ position: TextLineStorage<TextLine>.TextLinePosition,
        whitespaceOffset: CGFloat = 0,
        textStorage: NSTextStorage,
        layoutData: LineLayoutData
    ) -> CGSize {
        let lineDisplayData = TextLine.DisplayData(
            maxWidth: layoutData.maxWidth,
            lineHeightMultiplier: lineHeightMultiplier,
            estimatedLineHeight: estimateLineHeight(),
            breakStrategy: lineBreakStrategy
        )

        // Dispatch to the pre-bound closure if the render delegate installed one, otherwise go straight to the
        // default path. No witness-table lookup or weak-ref load on the common (no-override) path.
        let line = position.data
        let markedRanges = markedTextManager.markedRanges(in: position.range)
        let lineAttachments = attachments.getAttachmentsStartingIn(position.range)
        if let prepareOverride = _prepareForDisplayOverride {
            prepareOverride(line, lineDisplayData, position.range, textStorage, markedRanges, lineAttachments)
        } else {
            line.prepareForDisplay(
                displayData: lineDisplayData,
                range: position.range,
                stringRef: textStorage,
                markedRanges: markedRanges,
                attachments: lineAttachments
            )
        }

        if position.range.isEmpty {
            return CGSize(width: 0, height: estimateLineHeight())
        }

        var height: CGFloat = 0
        var width: CGFloat = 0
        let xOrigin = edgeInsets.left
        let lineY = position.yPos + whitespaceOffset

        for lineFragmentPosition in line.lineFragments {
            let lineFragment = lineFragmentPosition.data
            lineFragment.documentRange = lineFragmentPosition.range.translate(location: position.range.location)

            visibleFragments.append(
                VisibleFragment(
                    fragment: lineFragment,
                    xPos: xOrigin,
                    yPos: lineY + lineFragmentPosition.yPos,
                    width: lineFragment.width,
                    height: lineFragment.scaledHeight
                )
            )

            width = max(width, lineFragment.width)
            height += lineFragment.scaledHeight
        }

        return CGSize(width: width, height: height)
    }

    /// Appends fragments of an already-laid-out line to `visibleFragments`. Used for lines that skipped typesetting.
    private func appendVisibleFragments(
        for position: TextLineStorage<TextLine>.TextLinePosition,
        whitespaceOffset: CGFloat
    ) {
        let line = position.data
        let xOrigin = edgeInsets.left
        let lineY = position.yPos + whitespaceOffset

        for lineFragmentPosition in line.lineFragments {
            let lineFragment = lineFragmentPosition.data
            lineFragment.documentRange = lineFragmentPosition.range.translate(location: position.range.location)

            visibleFragments.append(
                VisibleFragment(
                    fragment: lineFragment,
                    xPos: xOrigin,
                    yPos: lineY + lineFragmentPosition.yPos,
                    width: lineFragment.width,
                    height: lineFragment.scaledHeight
                )
            )
        }
    }
}
