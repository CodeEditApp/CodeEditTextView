//
//  Emphasis.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 3/31/25.
//

import AppKit

/// Represents a single emphasis with its properties
public struct Emphasis {
    public let range: NSRange
    public let style: EmphasisStyle
    public let flash: Bool
    public let inactive: Bool
    public let select: Bool

    public init(
        range: NSRange,
        style: EmphasisStyle = .standard,
        flash: Bool = false,
        inactive: Bool = false,
        select: Bool = false
    ) {
        self.range = range
        self.style = style
        self.flash = flash
        self.inactive = inactive
        self.select = select
    }
}
