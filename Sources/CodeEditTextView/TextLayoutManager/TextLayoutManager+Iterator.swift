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
    func visibleLines() -> Iterator {
        let visibleRect = delegate?.visibleRect ?? NSRect(
            x: 0,
            y: 0,
            width: 0,
            height: estimatedHeight()
        )
        return Iterator(minY: max(visibleRect.minY, 0), maxY: max(visibleRect.maxY, 0), storage: self.lineStorage)
    }
    
    /// Iterate over all lines in the y position range.
    /// - Parameters:
    ///   - minY: The minimum y position to begin at.
    ///   - maxY: The maximum y position to iterate to.
    /// - Returns: An iterator that will iterate through all text lines in the y position range.
    func linesStartingAt(_ minY: CGFloat, until maxY: CGFloat) -> TextLineStorage<TextLine>.TextLineStorageYIterator {
        lineStorage.linesStartingAt(minY, until: maxY)
    }

    struct Iterator: LazySequenceProtocol, IteratorProtocol {
        private var storageIterator: TextLineStorage<TextLine>.TextLineStorageYIterator

        init(minY: CGFloat, maxY: CGFloat, storage: TextLineStorage<TextLine>) {
            storageIterator = storage.linesStartingAt(minY, until: maxY)
        }

        public mutating func next() -> TextLineStorage<TextLine>.TextLinePosition? {
            storageIterator.next()
        }
    }
}
