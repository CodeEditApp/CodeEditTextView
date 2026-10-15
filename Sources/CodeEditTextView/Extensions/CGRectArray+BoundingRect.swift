//
//  File.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 7/17/25.
//

import AppKit

extension Array where Element == CGRect {
    /// Returns a rect object that contains all of the rects in this array.
    /// Returns `.zero` if the array is empty.
    /// - Returns: The minimum rectangle that contains all rectangles in this array.
    func boundingRect() -> CGRect {
        guard let first else { return .zero }
        var minX = Swift.min(first.origin.x, first.origin.x + first.size.width)
        var maxX = Swift.max(first.origin.x, first.origin.x + first.size.width)
        var minY = Swift.min(first.origin.y, first.origin.y + first.size.height)
        var maxY = Swift.max(first.origin.y, first.origin.y + first.size.height)
        for rect in dropFirst() {
            let x2 = rect.origin.x + rect.size.width
            let y2 = rect.origin.y + rect.size.height
            minX = Swift.min(minX, Swift.min(rect.origin.x, x2))
            maxX = Swift.max(maxX, Swift.max(rect.origin.x, x2))
            minY = Swift.min(minY, Swift.min(rect.origin.y, y2))
            maxY = Swift.max(maxY, Swift.max(rect.origin.y, y2))
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
