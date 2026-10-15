//
//  LineInk.swift
//  CodeEditTextView
//

import CoreText
import Foundation
import os
import simd

/// How far a `CTLine`'s pixels reach, y-up from its baseline: the union of its glyphs' bounding rects at their
/// positions, plus the lowest underline. ``LineFragment`` turns it into ``LineFragment/inkOverflowAbove`` and
/// ``LineFragment/inkOverflowBelow``.
///
/// The glyph part equals `CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)`, which re-measures every glyph on
/// every call: about 21 µs for an 81-glyph line, which made a full relayout 7.3× as expensive. ``measure(_:)``
/// measures each glyph once per font (``GlyphExtentTable``) and then costs one pass over the line's glyphs (about
/// 150 ns for that line). ``TypesetCache`` stores the result with the line, so a cache hit measures nothing.
struct LineInk: Equatable {
    /// The highest point any glyph reaches; `-infinity` when no glyph has ink.
    var top: CGFloat
    /// The lowest point any glyph or underline reaches; `+infinity` when there is neither.
    var bottom: CGFloat
    /// Whether any glyph is positioned off the baseline (fonts stack combining marks this way).
    var hasVerticalGlyphOffsets: Bool

    static let empty = LineInk(top: -.infinity, bottom: .infinity, hasVerticalGlyphOffsets: false)

    mutating func formUnion(_ other: LineInk) {
        top = max(top, other.top)
        bottom = min(bottom, other.bottom)
        hasVerticalGlyphOffsets = hasVerticalGlyphOffsets || other.hasVerticalGlyphOffsets
    }

    /// The ink of `line`. Thread-safe: the per-font tables sit behind one lock, taken once per call.
    static func measure(_ line: CTLine) -> LineInk {
        glyphExtentCache.withLockUnchecked { $0.measure(line) }
    }

    /// The ink of every text content in `contents`, under one lock.
    static func measure(_ contents: [LineFragment.FragmentContent]) -> LineInk {
        glyphExtentCache.withLockUnchecked { cache in
            var ink = LineInk.empty
            for content in contents {
                guard case .text(let line) = content.data else { continue }
                ink.formUnion(cache.measure(line))
            }
            return ink
        }
    }
}

// `OSAllocatedUnfairLock` rather than `Synchronization.Mutex`, which needs macOS 15. The unchecked variants: the cache
// holds non-Sendable Core Text objects, which it only touches under the lock.
private let glyphExtentCache = OSAllocatedUnfairLock(uncheckedState: GlyphExtentCache())

// The CF names of the two attributes read per run. They are the same strings as `NSAttributedString.Key.font` and
// `.underlineStyle` ("NSFont", "NSUnderline"); CF lookups skip bridging the run's attribute dictionary.
private nonisolated(unsafe) let fontAttributeKey = unsafeBitCast(kCTFontAttributeName, to: UnsafeRawPointer.self)
private nonisolated(unsafe) let underlineAttributeKey = unsafeBitCast(
    kCTUnderlineStyleAttributeName, to: UnsafeRawPointer.self
)

/// Glyph extent tables, one per distinct font.
///
/// Core Text hands out a fresh `CTFont` instance for every fallback run, so tables are keyed by font equality
/// (`CFEqual`), with an identity check against the last font first: almost every run uses the document font.
///
/// Before any of that, a run whose attribute dictionary is the very object the previous run had reuses that run's
/// font table and underline: runs typeset from one text storage attribute run share its dictionary (one object
/// across a whole code file), and the two dictionary lookups were half of a short line's measurement.
struct GlyphExtentCache {
    /// More distinct fonts than this (sizes × fallbacks) clears the cache rather than growing it without bound.
    static let capacity = 32

    /// What a run's attributes mean for its ink: the font's table (nil without a font), and the lowest underline
    /// (`+infinity` when the run isn't underlined).
    private struct RunStyle {
        var table: GlyphExtentTable?
        var underlineBottom: CGFloat
    }

    private var lastAttributes: CFDictionary?
    private var lastStyle = RunStyle(table: nil, underlineBottom: .infinity)
    private var lastFont: CTFont?
    private var lastTable: GlyphExtentTable?
    private var tables: [FontKey: GlyphExtentTable] = [:]

    private struct FontKey: Hashable {
        let font: CTFont
        let hash: Int

        init(_ font: CTFont) {
            self.font = font
            self.hash = Int(bitPattern: UInt(CFHash(font)))
        }

        static func == (lhs: FontKey, rhs: FontKey) -> Bool {
            lhs.hash == rhs.hash && CFEqual(lhs.font, rhs.font)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(hash)
        }
    }

    mutating func table(for font: CTFont) -> GlyphExtentTable {
        if let lastFont, lastFont === font, let lastTable {
            return lastTable
        }
        let key = FontKey(font)
        let table: GlyphExtentTable
        if let found = tables[key] {
            table = found
        } else {
            if tables.count >= Self.capacity {
                tables.removeAll(keepingCapacity: true)
            }
            table = GlyphExtentTable(font: font)
            tables[key] = table
        }
        lastFont = font
        lastTable = table
        return table
    }

    private mutating func runStyle(_ attributes: CFDictionary) -> RunStyle {
        // Attribute dictionaries are immutable once Core Text holds them, so the same object means the same style.
        if let lastAttributes, lastAttributes === attributes {
            return lastStyle
        }
        var style = RunStyle(table: nil, underlineBottom: .infinity)
        if let fontValue = CFDictionaryGetValue(attributes, fontAttributeKey) {
            let table = table(for: unsafeBitCast(fontValue, to: CTFont.self))
            style.table = table
            if let styleValue = CFDictionaryGetValue(attributes, underlineAttributeKey),
               let underline = (unsafeBitCast(styleValue, to: AnyObject.self) as? NSNumber)?.intValue,
               underline != 0 {
                style.underlineBottom = table.underlineBottom
            }
        }
        lastAttributes = attributes
        lastStyle = style
        return style
    }

    mutating func measure(_ line: CTLine) -> LineInk {
        var low = CGFloat.infinity
        var high = -CGFloat.infinity
        var underline = CGFloat.infinity
        var hasOffsets = false
        var needsCoreTextBounds = false

        let runs = CTLineGetGlyphRuns(line)
        for runIndex in 0..<CFArrayGetCount(runs) {
            let run = unsafeBitCast(CFArrayGetValueAtIndex(runs, runIndex), to: CTRun.self)
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let style = runStyle(CTRunGetAttributes(run))
            // Underlines (marked text, for one) are drawn by Core Text but aren't glyph paths.
            underline = min(underline, style.underlineBottom)
            guard let table = style.table else {
                // No font to measure with; let Core Text measure the line. Never seen from CTTypesetter output.
                needsCoreTextBounds = true
                hasOffsets = hasOffsets || Self.hasVerticalOffsets(run, count: count)
                continue
            }
            if CTRunGetStatus(run).contains(.hasNonIdentityMatrix) {
                // The table holds untransformed glyph rects; let Core Text apply the run's matrix.
                needsCoreTextBounds = true
                hasOffsets = hasOffsets || Self.hasVerticalOffsets(run, count: count)
                continue
            }
            Self.withGlyphsAndPositions(run, count: count) { glyphs, positions in
                let run = table.extent(glyphs: glyphs, positions: positions, count: count)
                low = min(low, run.low)
                high = max(high, run.high)
                hasOffsets = hasOffsets || run.hasOffsets
            }
        }

        if needsCoreTextBounds {
            let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            if bounds.isNull || bounds.isEmpty {
                low = .infinity
                high = -.infinity
            } else {
                low = bounds.minY
                high = bounds.maxY
            }
        }
        // As `CTLineGetBoundsWithOptions`: bounds without height are empty.
        if !(high > low) {
            low = .infinity
            high = -.infinity
        }
        return LineInk(top: high, bottom: min(low, underline), hasVerticalGlyphOffsets: hasOffsets)
    }

    @inline(__always)
    private static func withGlyphsAndPositions(
        _ run: CTRun,
        count: Int,
        _ body: (UnsafePointer<CGGlyph>, UnsafePointer<CGPoint>) -> Void
    ) {
        // Core Text's pointers are valid while `run` is alive, which the caller's line guarantees.
        if let glyphs = CTRunGetGlyphsPtr(run), let positions = CTRunGetPositionsPtr(run) {
            body(glyphs, positions)
            return
        }
        // Rare (some fallback runs): copy both into scratch space sized to the run.
        withUnsafeTemporaryAllocation(of: CGGlyph.self, capacity: count) { glyphs in
            withUnsafeTemporaryAllocation(of: CGPoint.self, capacity: count) { positions in
                guard let glyphBase = glyphs.baseAddress, let positionBase = positions.baseAddress else { return }
                CTRunGetGlyphs(run, CFRange(location: 0, length: count), glyphBase)
                CTRunGetPositions(run, CFRange(location: 0, length: count), positionBase)
                body(glyphBase, positionBase)
            }
        }
    }

    private static func hasVerticalOffsets(_ run: CTRun, count: Int) -> Bool {
        var found = false
        withGlyphsAndPositions(run, count: count) { _, positions in
            // `positions` holds `count` points.
            for index in 0..<count where positions[index].y != 0 {
                found = true
                return
            }
        }
        return found
    }
}

/// Every glyph's vertical extent in one font, measured once: `(-minY, maxY)` y-up from the baseline (negated so one
/// maximum tracks both bounds), or `(-inf, -inf)` for a glyph without ink.
///
/// Glyph IDs are 16 bits, split into 256 pages of 256. A page is measured with one
/// `CTFontGetBoundingRectsForGlyphs` call the first time a glyph in it is drawn, so a code font touches one or two
/// pages (4 KB each) and a CJK font only the pages its text uses. Extents stay `Double`, so a line's ink equals what
/// Core Text reports for it; `Float` was off by up to 5e-7 pt for sizes that aren't binary fractions.
final class GlyphExtentTable {
    let font: CTFont
    /// The lowest point of a single, double or thick underline in this font: about twice the thickness below its
    /// position.
    let underlineBottom: CGFloat

    private static let pageCount = 256
    private static let pageSize = 256
    private let pages: UnsafeMutablePointer<UnsafeMutablePointer<SIMD2<Double>>?>

    init(font: CTFont) {
        self.font = font
        self.underlineBottom = CTFontGetUnderlinePosition(font) - 2 * CTFontGetUnderlineThickness(font)
        // Owned by this table and freed in deinit; 256 pointers cover every 16-bit glyph ID.
        pages = .allocate(capacity: Self.pageCount)
        pages.initialize(repeating: nil, count: Self.pageCount)
    }

    deinit {
        for index in 0..<Self.pageCount {
            // Each non-nil page was allocated by `fill(page:)` and is freed exactly once here.
            pages[index]?.deallocate()
        }
        pages.deallocate()
    }

    /// The vertical extent of `count` glyphs drawn at `positions`, and whether any sits off the baseline.
    ///
    /// Branch-free and in registers: per glyph, one vector add and two `fmaxnm.2d` (bounds, and the baseline
    /// offsets), split over two accumulator sets so consecutive glyphs don't wait on each other. Scalar `min`/`max`
    /// on variables captured by the run closure kept them in memory and cost 5.5 ns per glyph; this costs about 1.8
    /// (`simd_max`; the stdlib's `pointwiseMax` is scalarized with NaN checks and is slower than scalar code).
    @inline(__always)
    func extent(
        glyphs: UnsafePointer<CGGlyph>,
        positions: UnsafePointer<CGPoint>,
        count: Int
    ) -> (low: CGFloat, high: CGFloat, hasOffsets: Bool) { // swiftlint:disable:this large_tuple
        let pages = self.pages
        @inline(__always)
        func entry(_ glyph: CGGlyph) -> SIMD2<Double> {
            let pageIndex = Int(glyph &>> 8)
            // `pageIndex` < 256 and `glyph & 0xFF` < 256 by construction: no bounds to check.
            let page = pages[pageIndex] ?? fill(page: pageIndex)
            return page[Int(glyph & 0xFF)]
        }
        // Entries are (-minY, maxY), so one maximum tracks both bounds: (-low, high). Offsets track (-y, y).
        var bounds0 = SIMD2<Double>(repeating: -.infinity), bounds1 = bounds0
        var offsets0 = SIMD2<Double>.zero, offsets1 = offsets0
        var index = 0
        // The caller passes `count` valid elements in both buffers.
        while index + 1 < count {
            let y0 = Double(positions[index].y)
            let y1 = Double(positions[index + 1].y)
            let shift0 = SIMD2(-y0, y0)
            let shift1 = SIMD2(-y1, y1)
            bounds0 = simd_max(bounds0, entry(glyphs[index]) + shift0)
            bounds1 = simd_max(bounds1, entry(glyphs[index + 1]) + shift1)
            offsets0 = simd_max(offsets0, shift0)
            offsets1 = simd_max(offsets1, shift1)
            index &+= 2
        }
        if index < count {
            let y0 = Double(positions[index].y)
            let shift = SIMD2(-y0, y0)
            bounds0 = simd_max(bounds0, entry(glyphs[index]) + shift)
            offsets0 = simd_max(offsets0, shift)
        }
        let bounds = simd_max(bounds0, bounds1)
        let offsets = simd_max(offsets0, offsets1)
        // A glyph without ink is stored as (-inf, -inf), which neither maximum can pick.
        return (CGFloat(-bounds.x), CGFloat(bounds.y), offsets.x > 0 || offsets.y > 0)
    }

    @inline(never)
    private func fill(page pageIndex: Int) -> UnsafeMutablePointer<SIMD2<Double>> {
        // Owned by `pages` from here on; freed in deinit.
        let page = UnsafeMutablePointer<SIMD2<Double>>.allocate(capacity: Self.pageSize)
        withUnsafeTemporaryAllocation(of: CGGlyph.self, capacity: Self.pageSize) { glyphs in
            withUnsafeTemporaryAllocation(of: CGRect.self, capacity: Self.pageSize) { rects in
                guard let glyphBase = glyphs.baseAddress, let rectBase = rects.baseAddress else {
                    page.initialize(repeating: SIMD2(repeating: -.infinity), count: Self.pageSize)
                    return
                }
                for index in 0..<Self.pageSize {
                    glyphBase[index] = CGGlyph(truncatingIfNeeded: pageIndex &<< 8 | index)
                }
                CTFontGetBoundingRectsForGlyphs(font, .default, glyphBase, rectBase, Self.pageSize)
                for index in 0..<Self.pageSize {
                    let rect = rectBase[index]
                    let extent = rect.isNull || rect.isEmpty
                        ? SIMD2<Double>(repeating: -.infinity)
                        : SIMD2(-Double(rect.minY), Double(rect.maxY))
                    (page + index).initialize(to: extent)
                }
            }
        }
        pages[pageIndex] = page
        return page
    }
}
