//
//  TextLayoutManager+Iterator.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 8/21/23.
//

import Foundation

public extension TextLayoutManager {
    /// Iterate over all visible lines.
    ///
    /// Visible lines are any lines contained by the rect returned by ``TextLayoutManagerDelegate/visibleRect`` or,
    /// if there is no delegate from `0` to the estimated document height.
    ///
    /// - Returns: An iterator to iterate through all visible lines.
    func visibleLines() -> YPositionIterator {
        let visibleRect = delegate?.visibleRect ?? NSRect(
            x: 0,
            y: 0,
            width: 0,
            height: estimatedHeight()
        )
        return YPositionIterator(minY: max(visibleRect.minY, 0), maxY: max(visibleRect.maxY, 0), layoutManager: self)
    }

    /// Iterate over all lines in the y position range.
    /// - Parameters:
    ///   - minY: The minimum y position to begin at.
    ///   - maxY: The maximum y position to iterate to.
    /// - Returns: An iterator that will iterate through all text lines in the y position range.
    func linesStartingAt(_ minY: CGFloat, until maxY: CGFloat) -> YPositionIterator {
        YPositionIterator(minY: minY, maxY: maxY, layoutManager: self)
    }
    /// Iterate over all lines that overlap a document range.
    /// - Parameters:
    ///   - range: The range in the document to iterate over.
    /// - Returns: An iterator for lines in the range. The iterator returns lines that *overlap* with the range.
    ///            Returned lines may extend slightly before or after the queried range.
    func linesInRange(_ range: NSRange) -> RangeIterator {
        RangeIterator(range: range, layoutManager: self)
    }

    /// This iterator iterates over "visible" text positions that overlap a range of vertical `y` positions
    /// using ``TextLayoutManager/determineVisiblePosition(for:)``.
    ///
    /// Next elements are retrieved lazily. Additionally, this iterator uses a stable `index` rather than a y position
    /// or a range to fetch the next line. This means the line storage can be updated during iteration.
    struct YPositionIterator: LazySequenceProtocol, IteratorProtocol {
        typealias TextLinePosition = TextLineStorage<TextLine>.TextLinePosition

        /// Strong reference - these iterators are handed out by public API (``TextLayoutManager/visibleLines()``,
        /// ``TextLayoutManager/linesStartingAt(_:until:)``) and may outlive the layout manager's other owners.
        /// One retain per iterator creation; `next()` itself pays no weak-ref or liveness-check cost.
        @usableFromInline let layoutManager: TextLayoutManager
        @usableFromInline let minY: CGFloat
        @usableFromInline let maxY: CGFloat
        @usableFromInline var cursor: VisibleLineCursor

        init(minY: CGFloat, maxY: CGFloat, layoutManager: TextLayoutManager) {
            self.minY = minY
            self.maxY = maxY
            self.layoutManager = layoutManager
            self.cursor = VisibleLineCursor(storage: layoutManager.lineStorage)
        }

        /// Iterates over the "visible" text positions.
        ///
        /// See documentation on ``TextLayoutManager/determineVisiblePosition(for:)`` for details. Inlinable, so a
        /// caller in another module (CESE's gutter) runs the specialized walk.
        @inlinable
        public mutating func next() -> TextLineStorage<TextLine>.TextLinePosition? {
            if cursor.hasPosition {
                guard let nextPosition = layoutManager.advance(&cursor), nextPosition.yPos < maxY else {
                    return nil
                }
                return nextPosition
            }
            return layoutManager.startVisibleLines(
                at: layoutManager.lineStorage.getLine(atPosition: minY),
                cursor: &cursor
            )
        }
    }

    /// This iterator iterates over "visible" text positions that overlap a document using
    /// ``TextLayoutManager/determineVisiblePosition(for:)``.
    ///
    /// Next elements are retrieved lazily. Additionally, this iterator uses a stable `index` rather than a y position
    /// or a range to fetch the next line. This means the line storage can be updated during iteration.
    struct RangeIterator: LazySequenceProtocol, IteratorProtocol {
        typealias TextLinePosition = TextLineStorage<TextLine>.TextLinePosition

        /// Strong reference - see `YPositionIterator` for rationale.
        @usableFromInline let layoutManager: TextLayoutManager
        @usableFromInline let range: NSRange
        @usableFromInline var cursor: VisibleLineCursor

        init(range: NSRange, layoutManager: TextLayoutManager) {
            self.range = range
            self.layoutManager = layoutManager
            self.cursor = VisibleLineCursor(storage: layoutManager.lineStorage)
        }

        /// Iterates over the "visible" text positions.
        ///
        /// See documentation on ``TextLayoutManager/determineVisiblePosition(for:)`` for details. Inlinable, see
        /// `YPositionIterator`.
        @inlinable
        public mutating func next() -> TextLineStorage<TextLine>.TextLinePosition? {
            if cursor.hasPosition {
                guard let nextPosition = layoutManager.advance(&cursor),
                      nextPosition.range.location < range.location + range.length else {
                    return nil
                }
                return nextPosition
            }
            return layoutManager.startVisibleLines(
                at: layoutManager.lineStorage.getLine(atOffset: range.location),
                cursor: &cursor
            )
        }
    }

    /// Where a visible-line iterator stands: the last position it returned, kept as plain fields. Holding that
    /// position in an optional (with or without its index range) cost a copy and a destroy through runtime value
    /// witnesses on every step, more than the walk itself.
    @usableFromInline
    internal struct VisibleLineCursor {
        /// The layout manager's line storage, read once. (`lineStorage` is never reassigned; reading the class
        /// property on every step cost a dynamic exclusivity check per line.)
        @usableFromInline let storage: TextLineStorage<TextLine>
        /// Whether a position has been returned yet.
        @usableFromInline var hasPosition = false
        /// The last returned position's location, y position and index.
        @usableFromInline var location = 0
        @usableFromInline var yPos: CGFloat = 0
        @usableFromInline var index = 0
        /// The index of the last line merged into that position; equal to `index` unless attachments merged lines.
        @usableFromInline var lastIndex = 0
        /// The storage node of the line at `lastIndex` when known, `Int32.min` otherwise.
        @usableFromInline var handle: TextLineStorage<TextLine>.NodeHandle = Int32.min

        @usableFromInline
        init(storage: TextLineStorage<TextLine>) {
            self.storage = storage
        }

        @usableFromInline
        mutating func move(
            to visible: (position: TextLineStorage<TextLine>.TextLinePosition, indexRange: ClosedRange<Int>)
        ) {
            hasPosition = true
            location = visible.position.range.location
            yPos = visible.position.yPos
            index = visible.position.index
            lastIndex = visible.indexRange.upperBound
            handle = Int32.min
        }
    }

    /// The first visible position of an iteration, starting from the storage line `position`.
    @usableFromInline
    internal func startVisibleLines(
        at position: TextLineStorage<TextLine>.TextLinePosition?,
        cursor: inout VisibleLineCursor
    ) -> TextLineStorage<TextLine>.TextLinePosition? {
        guard let visible = determineVisiblePosition(for: position) else { return nil }
        cursor.move(to: visible)
        return visible.position
    }

    /// Advances `cursor` to the next visible position and returns it, for the iterators above.
    ///
    /// Without attachments no lines merge, so this steps to the storage's in-order successor in O(1) amortized and
    /// builds the position from node fields read now, instead of an O(log n) `getLine(atIndex:)` search per line.
    /// Reading the fields at call time keeps the iterators' contract: the caller may change the height of the line it
    /// was just handed (layout does) before asking for the next one. That line's `yPos` and location stay valid
    /// through such a change; its height and length are re-read from its node.
    ///
    /// With attachments, merged lines resolve through ``determineVisiblePosition(for:)`` exactly as before
    /// (``advanceMergingLines(_:)``).
    @inlinable
    internal func advance(_ cursor: inout VisibleLineCursor) -> TextLineStorage<TextLine>.TextLinePosition? {
        guard attachments.isEmpty, cursor.index == cursor.lastIndex else {
            return advanceMergingLines(&cursor)
        }
        let storage = cursor.storage
        var currentHandle = cursor.handle
        if currentHandle == Int32.min {
            guard let found = storage.search(forIndex: cursor.lastIndex)?.handle else { return nil }
            currentHandle = found
        }
        let nextHandle = storage.successor(currentHandle)
        guard nextHandle != Int32.min else { return nil }
        let nodes = storage.nodesPtr
        let currentNode = nodes + Int(currentHandle)
        let nextNode = nodes + Int(nextHandle)
        let nextIndex = cursor.lastIndex + 1
        cursor.location += currentNode.pointee.length
        cursor.yPos += currentNode.pointee.height
        cursor.index = nextIndex
        cursor.lastIndex = nextIndex
        cursor.handle = nextHandle
        return TextLineStorage<TextLine>.TextLinePosition(
            data: storage.data(of: nextNode),
            range: NSRange(location: cursor.location, length: nextNode.pointee.length),
            yPos: cursor.yPos,
            height: nextNode.pointee.height,
            index: nextIndex
        )
    }

    /// ``advance(_:)`` when attachments may merge lines.
    @usableFromInline
    internal func advanceMergingLines(
        _ cursor: inout VisibleLineCursor
    ) -> TextLineStorage<TextLine>.TextLinePosition? {
        startVisibleLines(at: lineStorage.getLine(atIndex: cursor.lastIndex + 1), cursor: &cursor)
    }

    /// Determines the “visible” line position by merging any consecutive lines
    /// that are spanned by text attachments. If an attachment overlaps beyond the
    /// bounds of the original line, this method will extend the returned range to
    /// cover the full span of those attachments (and recurse if further attachments
    /// cross into newly included lines).
    ///
    /// For example, given the following:  *(`[` == attachment start, `]` == attachment end)*
    /// ```
    /// Line 1
    /// Line[ 2
    /// Line 3
    /// Line] 4
    /// ```
    /// If you start at the position for “Line 2”, the first and last attachments
    /// overlap lines 2–4, so this method will extend the range to cover lines 2–4
    /// and return a position whose `range` spans the entire attachment.
    ///
    /// # Why recursion?
    ///
    /// When an attachment extends the visible range, it may pull in new lines that themselves overlap other
    /// attachments. A simple one‐pass merge wouldn’t catch those secondary overlaps. By calling
    /// determineVisiblePosition again on the newly extended range, we ensure that all cascading attachments—no matter
    /// how many lines they span—are folded into a single, coherent TextLinePosition before returning.
    ///
    /// - Parameter originalPosition: The initial `TextLinePosition` to inspect.
    ///   Pass in the position you got from `lineStorage.getLine(atOffset:)` or similar.
    /// - Returns: A tuple containing `position`: A `TextLinePosition` whose `range` and `index` have been
    ///            adjusted to include any attachment‐spanned lines.. `indexRange`: A `ClosedRange<Int>` listing all of
    ///            the line indices that are now covered by the returned position.
    ///   Returns `nil` if `originalPosition` is `nil`.
    func determineVisiblePosition(
        for originalPosition: TextLineStorage<TextLine>.TextLinePosition?
    ) -> (position: TextLineStorage<TextLine>.TextLinePosition, indexRange: ClosedRange<Int>)? {
        guard let originalPosition else { return nil }
        return determineVisiblePositionRecursively(
            for: (originalPosition, originalPosition.index...originalPosition.index),
            recursionDepth: 0
        )
    }

    /// Private implementation of ``TextLayoutManager/determineVisiblePosition(for:)``.
    ///
    /// Separated for readability. This method does not have an optional parameter, and keeps track of a recursion
    /// depth.
    private func determineVisiblePositionRecursively(
        for originalPosition: (position: TextLineStorage<TextLine>.TextLinePosition, indexRange: ClosedRange<Int>),
        recursionDepth: Int
    ) -> (position: TextLineStorage<TextLine>.TextLinePosition, indexRange: ClosedRange<Int>)? {
        // Arbitrary max recursion depth. Ensures we don't spiral into in an infinite recursion.
        guard recursionDepth < 10 else {
            logger.warning("Visible position recursed for over 10 levels, returning early.")
            return originalPosition
        }

        let attachments = attachments.getAttachmentsOverlapping(originalPosition.position.range)
        guard let firstAttachment = attachments.first, let lastAttachment = attachments.last else {
            // No change, either no attachments or attachment doesn't span multiple lines.
            return originalPosition
        }

        var minIndex = originalPosition.indexRange.lowerBound
        var maxIndex = originalPosition.indexRange.upperBound
        var newPosition = originalPosition.position

        if firstAttachment.range.location < originalPosition.position.range.location,
           let extendedLinePosition = lineStorage.getLine(atOffset: firstAttachment.range.location) {
            newPosition = TextLineStorage<TextLine>.TextLinePosition(
                data: extendedLinePosition.data,
                range: NSRange(start: extendedLinePosition.range.location, end: newPosition.range.max),
                yPos: extendedLinePosition.yPos,
                height: extendedLinePosition.height,
                index: extendedLinePosition.index
            )
            minIndex = min(minIndex, newPosition.index)
        }

        // `>=` so an attachment ending exactly at this line's end (covering its line terminator) merges the next
        // line. `getAttachmentsOverlapping` includes attachments ending exactly at a queried line's start, so the
        // next line merges backwards at that boundary - the forward merge must match or the two queries disagree
        // and the layout pass lays this line out twice. `getLine(atOffset:)` returns `nil` for the document-end
        // offset when the last line is non-empty; clamp to the last line so attachments ending at the document
        // end still merge every line they cover.
        if lastAttachment.range.max >= originalPosition.position.range.max,
           let extendedLinePosition = lineStorage.getLine(atOffset: lastAttachment.range.max) ?? lineStorage.last {
            newPosition = TextLineStorage<TextLine>.TextLinePosition(
                data: newPosition.data,
                range: NSRange(start: newPosition.range.location, end: extendedLinePosition.range.max),
                yPos: newPosition.yPos,
                height: newPosition.height,
                index: newPosition.index // We want to keep the minimum index.
            )
            maxIndex = max(maxIndex, extendedLinePosition.index)
        }

        // Base case, we haven't updated anything
        if minIndex...maxIndex == originalPosition.indexRange {
            return (newPosition, minIndex...maxIndex)
        } else {
            // Recurse, to make sure we combine all necessary lines.
            return determineVisiblePositionRecursively(
                for: (newPosition, minIndex...maxIndex),
                recursionDepth: recursionDepth + 1
            )
        }
    }
}
