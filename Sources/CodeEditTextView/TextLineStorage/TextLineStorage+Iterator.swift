//
//  TextLineStorage+Iterator.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 7/16/23.
//

import Foundation

/// # Dev Note
///
/// All iterators use in-order successor walks (`successor(handle)`) for O(1)
/// amortized advancement. Each iterator tracks the current `NodeHandle` plus running
/// offset/yPos/index counters that are bumped by the current node's length/height on each step.
///
/// Everything an iteration touches is `@inlinable` (or `@usableFromInline`) so callers in other modules - CESE's gutter,
/// fold ribbon and fold calculator - get a specialized walk. Without it they ran the unspecialized generic code at
/// ~150 ns/line instead of ~7 ns/line.
///
/// The ``TextLinePosition`` iterators create each line's data if it doesn't exist yet. The ``LineSpan`` iterators don't,
/// for walks that need only ranges and heights.
public extension TextLineStorage {
    /// Iterate over all lines overlapping a range of `y` positions. Positions in the middle of line contents will
    /// return that line.
    /// - Parameters:
    ///   - minY: The minimum y position to start at.
    ///   - maxY: The maximum y position to stop at.
    /// - Returns: A lazy iterator for retrieving lines.
    @inlinable
    func linesStartingAt(_ minY: CGFloat, until maxY: CGFloat) -> TextLineStorageYIterator {
        TextLineStorageYIterator(storage: self, minY: minY, maxY: maxY)
    }

    /// Iterate over all lines overlapping a range in the document.
    /// - Parameter range: The range to query.
    /// - Returns: A lazy iterator for retrieving lines.
    @inlinable
    func linesInRange(_ range: NSRange) -> TextLineStorageRangeIterator {
        TextLineStorageRangeIterator(storage: self, range: range)
    }

    struct TextLineStorageYIterator: LazySequenceProtocol, IteratorProtocol {
        @usableFromInline let storage: TextLineStorage
        @usableFromInline let maxY: CGFloat
        @usableFromInline var currentHandle: NodeHandle
        @usableFromInline var textPos: Int
        @usableFromInline var yPos: CGFloat
        @usableFromInline var index: Int

        @inlinable
        init(storage: TextLineStorage, minY: CGFloat, maxY: CGFloat) {
            self.storage = storage
            self.maxY = maxY
            // Seed from a Y-position search to find the first overlapping node.
            if let pos = storage.search(forYPosition: Swift.max(minY, 0)) {
                self.currentHandle = pos.handle
                self.textPos = pos.textPos
                self.yPos = pos.yPos
                self.index = pos.index
            } else {
                self.currentHandle = Int32.min
                self.textPos = 0
                self.yPos = 0
                self.index = 0
            }
        }

        @inlinable
        public mutating func next() -> TextLinePosition? {
            guard currentHandle != Int32.min else { return nil }
            let ptr = storage.nodesPtr
            let node = ptr + Int(currentHandle)
            let nodeLength = node.pointee.length
            let nodeHeight = node.pointee.height

            guard yPos < maxY else { return nil }

            let result = TextLinePosition(
                data: storage.data(of: node),
                range: NSRange(location: textPos, length: nodeLength),
                yPos: yPos,
                height: nodeHeight,
                index: index
            )

            // Advance to successor
            let nextHandle = storage.successor(currentHandle)
            textPos += nodeLength
            yPos += nodeHeight
            index += 1
            currentHandle = nextHandle

            return result
        }
    }

    struct TextLineStorageRangeIterator: LazySequenceProtocol, IteratorProtocol {
        @usableFromInline let storage: TextLineStorage
        @usableFromInline let range: NSRange
        @usableFromInline var currentHandle: NodeHandle
        @usableFromInline var textPos: Int
        @usableFromInline var yPos: CGFloat
        @usableFromInline var index: Int

        @inlinable
        init(storage: TextLineStorage, range: NSRange) {
            self.storage = storage
            self.range = range
            // Seed from an offset search.
            if let pos = storage.search(for: range.location) {
                self.currentHandle = pos.handle
                self.textPos = pos.textPos
                self.yPos = pos.yPos
                self.index = pos.index
            } else {
                self.currentHandle = Int32.min
                self.textPos = 0
                self.yPos = 0
                self.index = 0
            }
        }

        @inlinable
        public mutating func next() -> TextLinePosition? {
            guard currentHandle != Int32.min else { return nil }
            let ptr = storage.nodesPtr
            let node = ptr + Int(currentHandle)
            let nodeLength = node.pointee.length
            let nodeHeight = node.pointee.height

            // Stop if we've passed the end of the requested range.
            guard textPos < range.location + range.length else { return nil }

            let result = TextLinePosition(
                data: storage.data(of: node),
                range: NSRange(location: textPos, length: nodeLength),
                yPos: yPos,
                height: nodeHeight,
                index: index
            )

            // Advance to successor
            let nextHandle = storage.successor(currentHandle)
            textPos += nodeLength
            yPos += nodeHeight
            index += 1
            currentHandle = nextHandle

            return result
        }
    }
}

extension TextLineStorage: LazySequenceProtocol {
    @inlinable
    public func makeIterator() -> TextLineStorageIterator {
        TextLineStorageIterator(storage: self)
    }

    public struct TextLineStorageIterator: IteratorProtocol {
        @usableFromInline let storage: TextLineStorage
        @usableFromInline var currentHandle: NodeHandle
        @usableFromInline var textPos: Int
        @usableFromInline var yPos: CGFloat
        @usableFromInline var index: Int

        @inlinable
        init(storage: TextLineStorage) {
            self.storage = storage
            // Seed at the leftmost (first) node.
            if storage.rootHandle != Int32.min {
                self.currentHandle = storage.minimum(storage.rootHandle)
                self.textPos = 0
                self.yPos = 0
                self.index = 0
            } else {
                self.currentHandle = Int32.min
                self.textPos = 0
                self.yPos = 0
                self.index = 0
            }
        }

        @inlinable
        public mutating func next() -> TextLinePosition? {
            guard currentHandle != Int32.min else { return nil }
            let ptr = storage.nodesPtr
            let node = ptr + Int(currentHandle)
            let nodeLength = node.pointee.length
            let nodeHeight = node.pointee.height

            let result = TextLinePosition(
                data: storage.data(of: node),
                range: NSRange(location: textPos, length: nodeLength),
                yPos: yPos,
                height: nodeHeight,
                index: index
            )

            // Advance to successor
            let nextHandle = storage.successor(currentHandle)
            textPos += nodeLength
            yPos += nodeHeight
            index += 1
            currentHandle = nextHandle

            return result
        }
    }
}

// MARK: - Line spans

public extension TextLineStorage {
    /// A line's place in the document, without its data.
    ///
    /// The storage creates a line's data the first time the line is read. Walks that need only ranges, positions or
    /// heights should use ``lineSpans()``, ``lineSpans(in:)`` and ``lineSpan(atOffset:)``, which never create it.
    struct LineSpan {
        /// The range of the line in the document.
        public let range: NSRange
        /// The y position of the line, on a top down y axis.
        public let yPos: CGFloat
        /// The height of the line.
        public let height: CGFloat
        /// The index of the line.
        public let index: Int
        /// The line's node, valid until the storage next changes.
        @usableFromInline let handle: NodeHandle

        @usableFromInline
        init(range: NSRange, yPos: CGFloat, height: CGFloat, index: Int, handle: NodeHandle) {
            self.range = range
            self.yPos = yPos
            self.height = height
            self.index = index
            self.handle = handle
        }

        @usableFromInline
        init(position: NodePosition) {
            self.init(
                range: NSRange(location: position.textPos, length: position.length),
                yPos: position.yPos,
                height: position.height,
                index: position.index,
                handle: position.handle
            )
        }
    }

    /// Iterate over the spans of all lines. Never creates line data.
    @inlinable
    func lineSpans() -> LineSpanIterator {
        LineSpanIterator(storage: self)
    }

    /// Iterate over the spans of the lines overlapping a range in the document: the lines ``linesInRange(_:)``
    /// returns. Never creates line data.
    @inlinable
    func lineSpans(in range: NSRange) -> LineSpanIterator {
        LineSpanIterator(storage: self, range: range)
    }

    /// The span of the line ``getLine(atOffset:)`` returns. Never creates line data.
    /// - Complexity: `O(log n)`
    @inlinable
    func lineSpan(atOffset offset: Int) -> LineSpan? {
        search(for: offset).map(LineSpan.init(position:))
    }

    /// The span of the line ``getLine(atIndex:)`` returns. Never creates line data.
    /// - Complexity: `O(log n)`
    @inlinable
    func lineSpan(atIndex index: Int) -> LineSpan? {
        search(forIndex: index).map(LineSpan.init(position:))
    }

    struct LineSpanIterator: LazySequenceProtocol, IteratorProtocol {
        @usableFromInline let storage: TextLineStorage
        /// Lines starting at or after this offset end the walk.
        @usableFromInline let endOffset: Int
        @usableFromInline var currentHandle: NodeHandle
        @usableFromInline var textPos: Int
        @usableFromInline var yPos: CGFloat
        @usableFromInline var index: Int

        @inlinable
        init(storage: TextLineStorage) {
            self.storage = storage
            self.endOffset = Int.max
            self.currentHandle = storage.rootHandle == Int32.min ? Int32.min : storage.minimum(storage.rootHandle)
            self.textPos = 0
            self.yPos = 0
            self.index = 0
        }

        @inlinable
        init(storage: TextLineStorage, range: NSRange) {
            self.storage = storage
            self.endOffset = range.location + range.length
            if let pos = storage.search(for: range.location) {
                self.currentHandle = pos.handle
                self.textPos = pos.textPos
                self.yPos = pos.yPos
                self.index = pos.index
            } else {
                self.currentHandle = Int32.min
                self.textPos = 0
                self.yPos = 0
                self.index = 0
            }
        }

        @inlinable
        public mutating func next() -> LineSpan? {
            guard currentHandle != Int32.min, textPos < endOffset else { return nil }
            let node = storage.nodesPtr + Int(currentHandle)
            let nodeLength = node.pointee.length
            let nodeHeight = node.pointee.height
            let result = LineSpan(
                range: NSRange(location: textPos, length: nodeLength),
                yPos: yPos,
                height: nodeHeight,
                index: index,
                handle: currentHandle
            )
            currentHandle = storage.successor(currentHandle)
            textPos += nodeLength
            yPos += nodeHeight
            index += 1
            return result
        }
    }
}
