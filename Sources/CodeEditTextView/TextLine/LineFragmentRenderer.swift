//
//  LineFragmentRenderer.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 6/10/25.
//

import AppKit
import CodeEditTextViewObjC

/// Manages drawing line fragments into a drawing context.
///
/// Subclass to override the drawing behavior (see `MinimapLineFragmentRenderer` for an example). Consumers inject a
/// subclass by setting `TextLayoutManager.lineFragmentRenderer`.
open class LineFragmentRenderer {
    private struct CacheKey: Hashable {
        let string: String
        let font: NSFont
        let color: NSColor
    }

    /// The same key compared by font and color identity. Hashing an `NSFont` and comparing it with `isEqual` for
    /// every invisible character cost more than drawing it, and delegates normally hand out the same cached
    /// instances. Holds them strongly, so an identity cannot be reused by another object while it is cached.
    private struct IdentityCacheKey: Hashable {
        let string: String
        let font: NSFont
        let color: NSColor

        static func == (lhs: IdentityCacheKey, rhs: IdentityCacheKey) -> Bool {
            lhs.font === rhs.font && lhs.color === rhs.color && lhs.string == rhs.string
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(ObjectIdentifier(font))
            hasher.combine(ObjectIdentifier(color))
            hasher.combine(string)
        }
    }

    /// Membership of a delegate's trigger characters: a bit per unit below 0x100, the rest in a set.
    struct TriggerSet {
        private var low = SIMD4<UInt64>(repeating: 0)
        private var high: Set<UInt16> = []

        init(_ characters: Set<UInt16>) {
            for character in characters {
                if character < 0x100 {
                    low[Int(character >> 6)] |= UInt64(1) << UInt64(character & 63)
                } else {
                    high.insert(character)
                }
            }
        }

        @inline(__always)
        func contains(_ character: UInt16) -> Bool {
            guard character < 0x100 else { return !high.isEmpty && high.contains(character) }
            return low[Int(character >> 6)] & (UInt64(1) << UInt64(character & 63)) != 0
        }
    }

    private struct InvisibleDrawingContext {
        let lineFragment: LineFragment
        let ctLine: CTLine
        let contentOffset: Int
        let position: CGPoint
        let context: CGContext
    }

    public weak var textStorage: NSTextStorage?
    public weak var invisibleCharacterDelegate: InvisibleCharactersDelegate?
    private var attributedStringCache: [CacheKey: CTLine] = [:]
    /// Front of ``attributedStringCache`` for repeated identical instances; see `IdentityCacheKey`.
    private var identityCache: [IdentityCacheKey: CTLine] = [:]

    /// Leading-edge caret offsets of ``caretOffsetsLine``, indexed from its string range start, or NaN where Core
    /// Text reports none (inside a grapheme cluster). Built once per scanned line: `CTLineGetOffsetForStringIndex`
    /// walks the line's carets on every call, so a call per invisible character was quadratic in the line length.
    private var caretOffsets: [CGFloat] = []
    private var caretOffsetsLine: CTLine?
    /// Hard cap on the replacement-character cache. Replacement glyphs are tiny in practice
    /// (a handful of distinct (char, font, color) combos), so this is generous.
    private static let attributedStringCacheCap: Int = 64

    // MARK: - Per-draw-pass snapshot

    /// Snapshot of the invisible character delegate's state, taken once per draw pass via ``beginDrawPass()`` to avoid
    /// repeated weak-ref loads + witness-table dispatches per fragment.
    private var _cachedTriggerCharacters: TriggerSet?
    /// Strong reference to the delegate for the duration of one draw pass. Set to `nil` after the pass.
    private var _drawPassDelegate: InvisibleCharactersDelegate?

    /// Call once before iterating `visibleFragments`. Snapshots the invisible-character delegate's trigger set and
    /// checks the cache-clear flag, so `draw(lineFragment:in:yPos:)` can skip the delegate entirely per fragment.
    public func beginDrawPass() {
        guard let delegate = invisibleCharacterDelegate else {
            endDrawPass()
            return
        }
        if delegate.invisibleStyleShouldClearCache() {
            attributedStringCache.removeAll(keepingCapacity: true)
            identityCache.removeAll(keepingCapacity: true)
        }
        _cachedTriggerCharacters = TriggerSet(delegate.triggerCharacters)
        _drawPassDelegate = delegate
    }

    /// Call after the draw pass completes to release the strong delegate reference.
    public func endDrawPass() {
        _cachedTriggerCharacters = nil
        _drawPassDelegate = nil
    }

    /// Create a fragment renderer.
    /// - Parameters:
    ///   - textStorage: The text storage backing the fragments being drawn.
    ///   - invisibleCharacterDelegate: A delegate object to interrogate for invisible character drawing.
    public init(textStorage: NSTextStorage?, invisibleCharacterDelegate: InvisibleCharactersDelegate?) {
        self.textStorage = textStorage
        self.invisibleCharacterDelegate = invisibleCharacterDelegate
    }

    /// Draw the given line fragment into a drawing context, using the invisible character configuration determined
    /// from the ``invisibleCharacterDelegate``, and line fragment information from the passed ``LineFragment`` object.
    /// - Parameters:
    ///   - lineFragment: The line fragment to drawn
    ///   - context: The drawing context to draw into.
    ///   - yPos: In the drawing context, what `y` position to start drawing at.
    open func draw(lineFragment: LineFragment, in context: CGContext, yPos: CGFloat) {
        // If beginDrawPass() was NOT called (e.g. subclass or standalone use), fall back to a per-fragment
        // delegate check.
        if _drawPassDelegate == nil, invisibleCharacterDelegate?.invisibleStyleShouldClearCache() == true {
            attributedStringCache.removeAll(keepingCapacity: true)
            identityCache.removeAll(keepingCapacity: true)
        }

        context.saveGState()
        // Removes jagged edges
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        // Effectively increases the screen resolution by drawing text in each LED color pixel (R, G, or B), rather than
        // the triplet of pixels (RGB) for a regular pixel. This can increase text clarity, but loses effectiveness
        // in low-contrast settings.
        context.setAllowsFontSubpixelPositioning(true)
        context.setShouldSubpixelPositionFonts(true)

        // Quantizes the position of each glyph, resulting in slightly less accurate positioning, and gaining higher
        // quality bitmaps and performance.
        context.setAllowsFontSubpixelQuantization(true)
        context.setShouldSubpixelQuantizeFonts(true)

        ContextSetHiddenSmoothingStyle(context, 16)

        context.textMatrix = .init(scaleX: 1, y: -1)

        var currentPosition: CGFloat = 0.0
        var currentLocation = 0
        for content in lineFragment.contents {
            context.saveGState()
            switch content.data {
            case .text(let ctLine):
                let baseline = CGPoint(
                    x: currentPosition,
                    y: yPos + lineFragment.height - lineFragment.descent + (lineFragment.heightDifference/2)
                ).pixelAligned
                if lineFragment.hasVerticalGlyphOffsets {
                    // Core Text applies glyph positions in user space, so under the flipped text matrix a mark
                    // the font stacks above its base glyph lands below it. Draw such lines in an unflipped space
                    // anchored at the baseline. (Lines without such offsets keep the flipped text matrix: the two
                    // round fractional baselines differently, and their pixels must not change.)
                    context.saveGState()
                    context.translateBy(x: baseline.x, y: baseline.y)
                    context.scaleBy(x: 1, y: -1)
                    context.textMatrix = .identity
                    context.textPosition = .zero
                    CTLineDraw(ctLine, context)
                    context.restoreGState()
                } else {
                    context.textPosition = baseline
                    CTLineDraw(ctLine, context)
                }

                drawInvisibles(
                    lineFragment: lineFragment,
                    for: ctLine,
                    contentOffset: currentLocation,
                    position: CGPoint(x: currentPosition, y: yPos),
                    in: context
                )
            case .attachment(let attachment):
                // Device-aligned so the attachment's fills look the same whichever rect a redraw clips to.
                attachment.attachment.draw(
                    in: context,
                    rect: context.deviceAligned(NSRect(
                        x: currentPosition,
                        y: yPos + (lineFragment.heightDifference/2),
                        width: attachment.width,
                        height: lineFragment.height
                    ))
                )
            }
            context.restoreGState()
            currentPosition += content.width
            currentLocation += content.length
        }
        context.restoreGState()
    }

    private func drawInvisibles(
        lineFragment: LineFragment,
        for ctLine: CTLine,
        contentOffset: Int,
        position: CGPoint,
        in context: CGContext
    ) {
        // Prefer the draw-pass snapshot (avoids weak-ref load + witness-table dispatch per fragment).
        // Fall back to the delegate directly for standalone/subclass callers that skip beginDrawPass().
        let delegate = _drawPassDelegate ?? invisibleCharacterDelegate
        guard let textStorage, let delegate else { return }

        let drawingContext = InvisibleDrawingContext(
            lineFragment: lineFragment,
            ctLine: ctLine,
            contentOffset: contentOffset,
            position: position,
            context: context
        )

        let characters = textStorage.string as NSString
        let range = createTextRange(for: drawingContext).clamped(to: characters.length)
        guard range.length > 0 else { return }
        // Scan the fragment's code units in place: a `String` substring per fragment plus a hashed set lookup per
        // character cost more than the drawing itself on a viewport of indented code.
        let triggerCharacters = _cachedTriggerCharacters ?? TriggerSet(delegate.triggerCharacters)
        withUnsafeTemporaryAllocation(of: UInt16.self, capacity: range.length) { buffer in
            guard let units = buffer.baseAddress else { return }
            characters.getCharacters(units, range: range)
            processInvisibleCharacters(
                in: UnsafeBufferPointer(buffer),
                range: range,
                delegate: delegate,
                triggerCharacters: triggerCharacters,
                drawingContext: drawingContext
            )
        }
    }

    private func createTextRange(for drawingContext: InvisibleDrawingContext) -> NSRange {
        // Scan only this text content's characters. The fragment may contain further contents
        // (attachments, more text) whose characters are scanned by their own passes.
        let start = drawingContext.lineFragment.documentRange.location + drawingContext.contentOffset
        let contentLength = CTLineGetStringRange(drawingContext.ctLine).length
        let end = min(start + contentLength, drawingContext.lineFragment.documentRange.max)
        return NSRange(start: start, end: max(start, end))
    }

    private func processInvisibleCharacters(
        in units: UnsafeBufferPointer<UInt16>,
        range: NSRange,
        delegate: InvisibleCharactersDelegate,
        triggerCharacters: TriggerSet,
        drawingContext: InvisibleDrawingContext
    ) {
        drawingContext.context.saveGState()
        defer { drawingContext.context.restoreGState() }

        lazy var offset = CTLineGetStringRange(drawingContext.ctLine).location

        for (idx, character) in units.enumerated()
        where triggerCharacters.contains(character) {
            processInvisibleCharacter(
                character: character,
                at: idx,
                in: range,
                offset: offset,
                delegate: delegate,
                drawingContext: drawingContext
            )
        }
    }

    // Disabling the next lint warning because I *cannot* figure out how to split this up further.

    private func processInvisibleCharacter( // swiftlint:disable:this function_parameter_count
        character: UInt16,
        at index: Int,
        in range: NSRange,
        offset: Int,
        delegate: InvisibleCharactersDelegate,
        drawingContext: InvisibleDrawingContext
    ) {
        guard let style = delegate.invisibleStyle(
            for: character,
            at: NSRange(start: range.location + index, end: range.max),
            lineRange: drawingContext.lineFragment.documentRange
        ) else {
            return
        }

        let xOffset = caretOffset(in: drawingContext.ctLine, at: offset + index)

        switch style {
        case let .replace(replacementCharacter, color, font):
            drawReplacementCharacter(
                replacementCharacter,
                color: color,
                font: font,
                at: calculateReplacementPosition(
                    basePosition: drawingContext.position,
                    xOffset: xOffset,
                    lineFragment: drawingContext.lineFragment
                ),
                in: drawingContext.context
            )
        case let .emphasize(color):
            let emphasizeRect = calculateEmphasisRect(
                basePosition: drawingContext.position,
                xOffset: xOffset,
                characterIndex: index,
                offset: offset,
                drawingContext: drawingContext
            )

            drawEmphasis(
                color: color,
                forRect: emphasizeRect,
                in: drawingContext.context
            )
        }
    }

    /// `CTLineGetOffsetForStringIndex(line, stringIndex, nil)`, from a table built once per line.
    func caretOffset(in line: CTLine, at stringIndex: Int) -> CGFloat {
        let lineRange = CTLineGetStringRange(line)
        if caretOffsetsLine !== line {
            var offsets = caretOffsets
            offsets.removeAll(keepingCapacity: true)
            offsets.append(contentsOf: repeatElement(CGFloat.nan, count: lineRange.length + 1))
            CTLineEnumerateCaretOffsets(line) { offset, index, leadingEdge, _ in
                let slot = index - lineRange.location
                // The first leading edge reported for an index is the primary offset the direct call returns.
                if leadingEdge, slot >= 0, slot < offsets.count, offsets[slot].isNaN {
                    offsets[slot] = offset
                }
            }
            caretOffsets = offsets
            caretOffsetsLine = line
        }
        let slot = stringIndex - lineRange.location
        if slot >= 0, slot < caretOffsets.count, !caretOffsets[slot].isNaN {
            return caretOffsets[slot]
        }
        return CTLineGetOffsetForStringIndex(line, stringIndex, nil)
    }

    private func calculateReplacementPosition(
        basePosition: CGPoint,
        xOffset: CGFloat,
        lineFragment: LineFragment
    ) -> CGPoint {
        return CGPoint(
            x: basePosition.x + xOffset,
            y: basePosition.y + lineFragment.height - lineFragment.descent + (lineFragment.heightDifference/2)
        )
    }

    private func calculateEmphasisRect(
        basePosition: CGPoint,
        xOffset: CGFloat,
        characterIndex: Int,
        offset: Int,
        drawingContext: InvisibleDrawingContext
    ) -> NSRect {
        let xEndOffset = if offset + characterIndex + 1 == drawingContext.lineFragment.documentRange.length {
            drawingContext.lineFragment.width
        } else {
            caretOffset(in: drawingContext.ctLine, at: offset + characterIndex + 1)
        }

        return NSRect(
            x: basePosition.x + xOffset,
            y: basePosition.y,
            width: xEndOffset - xOffset,
            height: drawingContext.lineFragment.scaledHeight
        )
    }

    private func drawReplacementCharacter(
        _ replacementCharacter: String,
        color: NSColor,
        font: NSFont,
        at position: CGPoint,
        in context: CGContext
    ) {
        let identityKey = IdentityCacheKey(string: replacementCharacter, font: font, color: color)
        if let cachedValue = identityCache[identityKey] {
            context.textPosition = position
            CTLineDraw(cachedValue, context)
            return
        }
        let cacheKey = CacheKey(string: replacementCharacter, font: font, color: color)
        let ctLine: CTLine
        if let cachedValue = attributedStringCache[cacheKey] {
            ctLine = cachedValue
        } else {
            let attrString = NSAttributedString(string: replacementCharacter, attributes: [
                .font: font,
                .foregroundColor: color
            ])
            ctLine = CTLineCreateWithAttributedString(attrString)
            if attributedStringCache.count >= Self.attributedStringCacheCap {
                // Simple cap-and-evict: drop everything when full. Replacement glyphs rarely
                // change at runtime; the cost of an occasional full rebuild is trivial.
                attributedStringCache.removeAll(keepingCapacity: true)
            }
            attributedStringCache[cacheKey] = ctLine
        }
        if identityCache.count >= Self.attributedStringCacheCap {
            identityCache.removeAll(keepingCapacity: true)
        }
        identityCache[identityKey] = ctLine
        context.textPosition = position
        CTLineDraw(ctLine, context)
    }

    private func drawEmphasis(
        color: NSColor,
        forRect: NSRect,
        in context: CGContext
    ) {
        context.setFillColor(color.cgColor)

        let rect: CGRect

        if forRect.width == 0 {
            // Zero-width character, add padding
            rect = CGRect(x: forRect.origin.x - 2, y: forRect.origin.y, width: 4, height: forRect.height)
        } else {
            rect = forRect
        }

        // Device-aligned so the fill looks the same whichever rect a redraw clips to.
        context.fill(context.deviceAligned(rect))
    }
}
