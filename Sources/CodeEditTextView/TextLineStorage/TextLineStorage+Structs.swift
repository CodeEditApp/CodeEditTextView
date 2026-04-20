//
//  TextLineStorage+Structs.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 8/24/23.
//

import Foundation

extension TextLineStorage where Data: Identifiable {
    public struct TextLinePosition {
        @usableFromInline
        init(data: Data, range: NSRange, yPos: CGFloat, height: CGFloat, index: Int) {
            self.data = data
            self.range = range
            self.yPos = yPos
            self.height = height
            self.index = index
        }

        @usableFromInline
        init(position: NodePosition) {
            self.data = position.data
            self.range = NSRange(location: position.textPos, length: position.length)
            self.yPos = position.yPos
            self.height = position.height
            self.index = position.index
        }

        /// The data stored at the position
        public let data: Data
        /// The range represented by the data
        public let range: NSRange
        /// The y position of the data, on a top down y axis
        public let yPos: CGFloat
        /// The height of the stored data
        public let height: CGFloat
        /// The index of the position.
        public let index: Int
    }

    /// Internal result type for tree searches. Carries the handle for mutation plus a
    /// snapshot of the node's user-facing fields so callers that only need to *read*
    /// the node don't have to go back through the arena subscript.
    @usableFromInline
    struct NodePosition {
        let handle: NodeHandle
        let data: Data
        let length: Int
        let height: CGFloat
        /// The y position of the data, on a top down y axis
        let yPos: CGFloat
        /// The location of the node in the document
        let textPos: Int
        /// The index of the node in the document.
        let index: Int

        @usableFromInline
        init(handle: NodeHandle, data: Data, length: Int, height: CGFloat, yPos: CGFloat, textPos: Int, index: Int) {
            self.handle = handle
            self.data = data
            self.length = length
            self.height = height
            self.yPos = yPos
            self.textPos = textPos
            self.index = index
        }
    }

    @usableFromInline
    struct NodeSubtreeMetadata {
        let height: CGFloat
        let offset: Int
        let count: Int

        @usableFromInline
        static var zero: NodeSubtreeMetadata {
            NodeSubtreeMetadata(height: 0, offset: 0, count: 0)
        }

        @usableFromInline
        static func + (lhs: NodeSubtreeMetadata, rhs: NodeSubtreeMetadata) -> NodeSubtreeMetadata {
            NodeSubtreeMetadata(
                height: lhs.height + rhs.height,
                offset: lhs.offset + rhs.offset,
                count: lhs.count + rhs.count
            )
        }
    }

    public struct BuildItem {
        public let data: Data
        public let length: Int
        public let height: CGFloat?

        public init(data: Data, length: Int, height: CGFloat?) {
            self.data = data
            self.length = length
            self.height = height
        }
    }
}
