//
//  TextLayoutManager+Invalidation.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 2/24/24.
//

import Foundation

extension TextLayoutManager {
    /// Invalidates layout for the given rect.
    /// - Parameter rect: The rect to invalidate.
    public func invalidateLayoutForRect(_ rect: NSRect) {
        for linePosition in lineStorage.linesStartingAt(rect.minY, until: rect.maxY) {
            linePosition.data.setNeedsLayout()
        }

        layoutView?.needsLayout = true
    }

    /// Invalidates layout for the given range of text.
    /// - Parameter range: The range of text to invalidate.
    public func invalidateLayoutForRange(_ range: NSRange) {
        for linePosition in lineStorage.linesInRange(range) {
            linePosition.data.setNeedsLayout()
        }

        layoutView?.needsLayout = true
    }

    public func setNeedsLayout() {
        needsLayout = true
        visibleLineIds.removeAll(keepingCapacity: true)
        layoutView?.needsLayout = true
    }
}
