//
//  LineFragment.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 6/29/23.
//

import AppKit
import CodeEditTextViewObjC

/// A ``LineFragment`` represents a subrange of characters in a line. Every text line contains at least one line
/// fragments, and any lines that need to be broken due to width constraints will contain more than one fragment.
public final class LineFragment: Identifiable, Equatable {
    public struct FragmentContent: Equatable {
        public enum Content: Equatable {
            case text(line: CTLine)
            case attachment(attachment: AnyTextAttachment)
        }

        public let data: Content
        public let width: CGFloat

        public var length: Int {
            switch data {
            case .text(let line):
                CTLineGetStringRange(line).length
            case .attachment(let attachment):
                attachment.range.length
            }
        }

#if DEBUG
        var isText: Bool {
            switch data {
            case .text:
                true
            case .attachment:
                false
            }
        }
#endif
    }

    public struct ContentPosition {
        let xPos: CGFloat
        let offset: Int
    }

    public let id = UniqueIdentifier.makeUUID()
    public var documentRange: NSRange = .notFound
    public var contents: [FragmentContent]
    public var width: CGFloat
    public var height: CGFloat
    public var descent: CGFloat
    public var scaledHeight: CGFloat

    /// How far the fragment's pixels reach above the top of its drawing rect (`scaledHeight` tall), in points.
    ///
    /// Glyphs can paint outside their line: stacked combining marks, tall fallback fonts, and the antialiased edge of
    /// a descender that ends right at the rect's bottom. A redraw of a neighboring line clears those pixels, so the
    /// fragment has to be drawn again with it - see ``VisibleFragment/drawMinY``.
    public private(set) var inkOverflowAbove: CGFloat = 0

    /// How far the fragment's pixels reach below the bottom of its drawing rect, in points. See ``inkOverflowAbove``.
    public private(set) var inkOverflowBelow: CGFloat = 0

    /// Whether any glyph is positioned off the baseline - combining marks stacked by the font, for instance.
    /// ``LineFragmentRenderer`` draws such text in an unflipped space so the offsets point the right way.
    public private(set) var hasVerticalGlyphOffsets: Bool = false

    /// The difference between the real text height and the scaled height
    public var heightDifference: CGFloat {
        scaledHeight - height
    }

    /// The glyph ink this fragment's contents paint, y-up from the baseline. ``TypesetCache`` keeps it with the
    /// typeset lines so a cache hit doesn't measure again.
    let ink: LineInk

    /// - Parameter ink: The contents' ink when it is already known (a ``TypesetCache`` hit); measured otherwise.
    init(
        contents: [FragmentContent],
        width: CGFloat,
        height: CGFloat,
        descent: CGFloat,
        lineHeightMultiplier: CGFloat,
        ink: LineInk? = nil
    ) {
        self.contents = contents
        self.width = width
        self.height = height
        self.descent = descent
        self.scaledHeight = height * lineHeightMultiplier
        let ink = ink ?? LineInk.measure(contents)
        self.ink = ink
        applyInk(ink)
    }

    /// Slack added to measured ink: the drawn baseline is rounded to a whole point (up to half a point away), and
    /// antialiasing touches the pixel past an exact path edge - a whole point at 1x.
    private static let inkSlack: CGFloat = 2

    /// Converts the contents' ink into how far it reaches past the drawing rect, using the baseline the renderer
    /// draws at. An empty bound (`-inf` top, `+inf` bottom) yields no overflow.
    private func applyInk(_ ink: LineInk) {
        let baseline = height - descent + heightDifference / 2
        // Line bounds are y-up from the baseline; the fragment is drawn top-down.
        inkOverflowAbove = max(0, ink.top - baseline + Self.inkSlack)
        inkOverflowBelow = max(0, baseline - ink.bottom - scaledHeight + Self.inkSlack)
        hasVerticalGlyphOffsets = ink.hasVerticalGlyphOffsets
    }

    public static func == (lhs: LineFragment, rhs: LineFragment) -> Bool {
        lhs.id == rhs.id
    }

    /// Finds the x position of the offset in the string the fragment represents.
    ///
    /// Prefer `TextLayoutManager.characterXPosition(in:for:)` at API boundaries - it honors the render delegate
    /// override used by the minimap. Inside the text view proper, where no render delegate is installed, callers can
    /// inline this directly; `TextLayoutManager` does exactly that for its hot selection/cursor paths.
    ///
    /// - Parameter offset: The offset, relative to the start of the *fragment* (content offsets accumulate from 0
    ///   within a fragment).
    /// - Returns: The x position of the character in the drawn line, from the left.
    @inline(__always)
    package func _xPos(for offset: Int) -> CGFloat {
        guard let (content, position) = findContent(at: offset) else {
            return width
        }
        switch content.data {
        case .text(let ctLine):
            return CTLineGetOffsetForStringIndex(
                ctLine,
                CTLineGetStringRange(ctLine).location + offset - position.offset,
                nil
            ) + position.xPos
        case .attachment:
            return position.xPos
        }
    }

    package func findContent(at location: Int) -> (content: FragmentContent, position: ContentPosition)? {
        var position = ContentPosition(xPos: 0, offset: 0)

        for content in contents {
            let length = content.length
            let width = content.width

            if (position.offset..<(position.offset + length)).contains(location) {
                return (content, position)
            }

            position = ContentPosition(xPos: position.xPos + width, offset: position.offset + length)
        }

        return nil
    }

    package func findContent(atX xPos: CGFloat) -> (content: FragmentContent, position: ContentPosition)? {
        var position = ContentPosition(xPos: 0, offset: 0)

        for content in contents {
            let length = content.length
            let width = content.width

            if (position.xPos..<(position.xPos + width)).contains(xPos) {
                return (content, position)
            }

            position = ContentPosition(xPos: position.xPos + width, offset: position.offset + length)
        }

        return nil
    }
}
