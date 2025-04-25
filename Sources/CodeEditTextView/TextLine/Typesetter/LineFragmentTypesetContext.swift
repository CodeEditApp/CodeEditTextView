//
//  LineFragmentTypesetContext.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 4/24/25.
//

import CoreGraphics

struct LineFragmentTypesetContext {
    var contents: [LineFragment.FragmentContent] = []
    var start: Int
    var width: CGFloat
    var height: CGFloat
    var descent: CGFloat

    mutating func clear() {
        contents.removeAll(keepingCapacity: true)
        width = 0
        height = 0
        descent = 0
    }
}
