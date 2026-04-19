//
//  LineDecoration.swift
//  CodeEditTextView
//
//  Created by Abe Malla on 4/12/26.
//

import AppKit

/// A line decoration represents a visual adornment applied to one or more lines of text in the editor.
///
/// Line decorations can add background colors to entire lines (e.g. for error highlights, current line
/// highlighting, search match line highlights), glyph margin decorations (e.g. breakpoint indicators),
/// or line-level CSS-like styling.
///
/// Decorations are identified by a unique ID and can be added/removed dynamically. They track
/// with text edits via their stickiness behavior.
///
/// Modeled after VSCode's `IModelDecoration` / `IModelDecorationOptions`.
public struct LineDecoration: Identifiable {
    /// Unique identifier for this decoration.
    public let id: UUID

    /// The range of line indices (0-based) this decoration applies to.
    public var lineRange: ClosedRange<Int>

    /// The visual style of this decoration.
    public var style: Style

    /// How the decoration range behaves when text is edited at its boundaries.
    public var stickiness: Stickiness

    /// An optional tag for grouping decorations (e.g. "error", "search-result", "current-line").
    /// Used for bulk removal of decorations by group.
    public var group: String?

    /// The type of visual decoration.
    public enum Style {
        /// A background color applied to the entire line(s).
        /// Used for current line highlight, error line backgrounds, search match highlights, etc.
        case lineBackground(color: NSColor)

        /// An overview ruler decoration — a small colored mark on the scrollbar.
        /// Used to show the position of errors, search results, and other items in the scrollbar.
        case overviewRuler(color: NSColor)

        /// A custom drawing callback for the line background.
        /// The closure receives the context, the rect for the line, and the line index.
        case custom(draw: (CGContext, CGRect, Int) -> Void)
    }

    /// Controls how the decoration range adjusts when text is edited at its boundaries.
    public enum Stickiness {
        /// The range does not grow when text is typed at its edges.
        case neverGrowsWhenTypingAtEdges
        /// The range grows on the right when text is typed at its right edge.
        case growsOnlyWhenTypingAfter
        /// The range always grows when text is typed at either edge.
        case alwaysGrowsWhenTypingAtEdges
    }

    public init(
        lineRange: ClosedRange<Int>,
        style: Style,
        stickiness: Stickiness = .growsOnlyWhenTypingAfter,
        group: String? = nil
    ) {
        self.id = UUID()
        self.lineRange = lineRange
        self.style = style
        self.stickiness = stickiness
        self.group = group
    }
}
