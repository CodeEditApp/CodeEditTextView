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
public extension TextLineStorage {
    /// Iterate over all lines overlapping a range of `y` positions. Positions in the middle of line contents will
    /// return that line.
    /// - Parameters:
    ///   - minY: The minimum y position to start at.
    ///   - maxY: The maximum y position to stop at.
    /// - Returns: A lazy iterator for retrieving lines.
    func linesStartingAt(_ minY: CGFloat, until maxY: CGFloat) -> TextLineStorageYIterator {
        TextLineStorageYIterator(storage: self, minY: minY, maxY: maxY)
    }

    /// Iterate over all lines overlapping a range in the document.
    /// - Parameter range: The range to query.
    /// - Returns: A lazy iterator for retrieving lines.
    func linesInRange(_ range: NSRange) -> TextLineStorageRangeIterator {
        TextLineStorageRangeIterator(storage: self, range: range)
    }

    struct TextLineStorageYIterator: LazySequenceProtocol, IteratorProtocol {
        private let storage: TextLineStorage
        private let maxY: CGFloat
        private var currentHandle: NodeHandle
        private var textPos: Int
        private var yPos: CGFloat
        private var index: Int

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

        public mutating func next() -> TextLinePosition? {
            guard currentHandle != Int32.min else { return nil }
            let ptr = storage.nodesPtr
            let node = ptr + Int(currentHandle)
            let nodeLength = node.pointee.length
            let nodeHeight = node.pointee.height

            guard yPos < maxY else { return nil }

            let result = TextLinePosition(
                data: node.pointee.data,
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
        private let storage: TextLineStorage
        private let range: NSRange
        private var currentHandle: NodeHandle
        private var textPos: Int
        private var yPos: CGFloat
        private var index: Int

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

        public mutating func next() -> TextLinePosition? {
            guard currentHandle != Int32.min else { return nil }
            let ptr = storage.nodesPtr
            let node = ptr + Int(currentHandle)
            let nodeLength = node.pointee.length
            let nodeHeight = node.pointee.height

            // Stop if we've passed the end of the requested range.
            guard textPos < range.location + range.length else { return nil }

            let result = TextLinePosition(
                data: node.pointee.data,
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
    public func makeIterator() -> TextLineStorageIterator {
        TextLineStorageIterator(storage: self)
    }

    public struct TextLineStorageIterator: IteratorProtocol {
        private let storage: TextLineStorage
        private var currentHandle: NodeHandle
        private var textPos: Int
        private var yPos: CGFloat
        private var index: Int

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

        public mutating func next() -> TextLinePosition? {
            guard currentHandle != Int32.min else { return nil }
            let ptr = storage.nodesPtr
            let node = ptr + Int(currentHandle)
            let nodeLength = node.pointee.length
            let nodeHeight = node.pointee.height

            let result = TextLinePosition(
                data: node.pointee.data,
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
