//
//  LineTerminatorScanner.swift
//  CodeEditTextView
//

import Foundation

/// Scans UTF-16 code units for line terminators with the exact semantics of
/// `NSString.getLineStart(_:end:contentsEnd:for:)`.
///
/// Terminators are U+000A (LINE FEED), U+000D (CARRIAGE RETURN), U+0085 (NEXT LINE), U+2028 (LINE
/// SEPARATOR) and U+2029 (PARAGRAPH SEPARATOR); CR LF is a single two-unit terminator. U+000B and
/// U+000C are *not* terminators. `LineTerminatorScannerTests` verifies all of this against Foundation
/// for every code unit.
///
/// The scanner is stateful so a document can be fed in windows; a CR LF pair straddling a window
/// boundary is handled through the `next` lookahead unit.
struct UTF16LineScanner {
    /// Code units per window when a string is fed through ``NSString/scanLineLengths(into:windowUnits:)``.
    /// 16K units is 32KB, resident in L1 on both performance and efficiency cores.
    static let defaultWindowUnits = 16_384

    /// Absolute offset of the first unit of the line currently being scanned.
    private(set) var lineStart = 0
    /// Absolute offset of the next unit to examine. Sits one past a window's end when a CR LF pair
    /// straddled the boundary, so the next window starts by skipping its consumed LF.
    private(set) var cursor = 0
    /// The final code unit of the most recently consumed terminator (LF for a CR LF pair); 0 before any.
    private(set) var lastTerminatorUnit: UInt16 = 0

    /// Scans `count` units at `buffer`, which represent absolute offsets `base ..< base + count`.
    /// - Parameters:
    ///   - next: The unit at absolute offset `base + count` if the document continues past this window.
    ///   - emit: Called with the UTF-16 length (content plus terminator) of each completed line and the
    ///     final code unit of its terminator (LF for a CR LF pair).
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    @inline(__always)
    mutating func scan(
        _ buffer: UnsafePointer<UInt16>,
        base: Int,
        count: Int,
        next: UInt16?,
        emit: (Int, UInt16) -> Void
    ) {
        var index = cursor - base

        let lineFeed = SIMD16<UInt16>(repeating: 0x0A)
        let carriageReturn = SIMD16<UInt16>(repeating: 0x0D)
        let nextLine = SIMD16<UInt16>(repeating: 0x85)
        let separatorMask = SIMD16<UInt16>(repeating: 0xFFFE) // U+2028 and U+2029 differ only in bit 0.
        let lineSeparator = SIMD16<UInt16>(repeating: 0x2028)
        // Prefilter ranges, each a wrapping subtract plus one unsigned compare: 0x0A...0x0D (LF, VT,
        // FF, CR - tab is excluded so indentation does not defeat the filter) and 0x85...0x2029.
        let controlBias = SIMD16<UInt16>(repeating: 0x0A)
        let controlSpan = SIMD16<UInt16>(repeating: 4)
        let highBias = SIMD16<UInt16>(repeating: 0x85)
        let highSpan = SIMD16<UInt16>(repeating: 0x2029 - 0x85 + 1)
        let laneBits = SIMD16<UInt16>(
            1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768
        )
        let zero = SIMD16<UInt16>(repeating: 0)

        while index + 16 <= count {
            let chunk = UnsafeRawPointer(buffer + index).loadUnaligned(as: SIMD16<UInt16>.self)
            let controlCandidates = (chunk &- controlBias) .< controlSpan
            let highCandidates = (chunk &- highBias) .< highSpan
            if !any(controlCandidates .| highCandidates) {
                index += 16
                continue
            }
            let isLineFeed = chunk .== lineFeed
            let isCarriageReturn = chunk .== carriageReturn
            let isNextLine = chunk .== nextLine
            let isSeparator = (chunk & separatorMask) .== lineSeparator
            let hits = (isLineFeed .| isCarriageReturn) .| (isNextLine .| isSeparator)
            // Movemask: one bit per hit lane, so each terminator is visited directly instead of
            // re-testing all 16 units one at a time.
            var bits = zero.replacing(with: laneBits, where: hits).wrappedSum()
            let blockStart = index
            while bits != 0 {
                let offset = blockStart + bits.trailingZeroBitCount
                bits &= bits &- 1
                // An LF that completed a preceding CR LF pair has already been consumed.
                if offset < index {
                    continue
                }
                let following: UInt16? = offset + 1 < count ? buffer[offset + 1] : next
                index = offset + consumeTerminator(buffer[offset], at: base + offset, following: following, emit: emit)
            }
            index = max(index, blockStart + 16)
        }

        // Scalar tail: fewer than 16 units remain in this window.
        while index < count {
            let unit = buffer[index]
            if unit == 0x0A || unit == 0x0D || unit == 0x85 || (unit & 0xFFFE) == 0x2028 {
                let following: UInt16? = index + 1 < count ? buffer[index + 1] : next
                index += consumeTerminator(unit, at: base + index, following: following, emit: emit)
            } else {
                index += 1
            }
        }
        cursor = base + index
    }

    /// Finishes the scan, emitting the trailing unterminated line (with terminator 0) if there is one.
    /// - Returns: The final unit of the last terminator when the document ended with one, `nil` otherwise.
    mutating func finish(totalLength: Int, emit: (Int, UInt16) -> Void) -> UInt16? {
        if lineStart < totalLength {
            emit(totalLength - lineStart, 0)
            lineStart = totalLength
            return nil
        }
        return totalLength > 0 ? lastTerminatorUnit : nil
    }

    /// Ends the current line at the terminator `unit` found at `absoluteOffset`.
    /// - Returns: The terminator's length in units: 2 for CR LF, otherwise 1.
    @inline(__always)
    private mutating func consumeTerminator(
        _ unit: UInt16,
        at absoluteOffset: Int,
        following: UInt16?,
        emit: (Int, UInt16) -> Void
    ) -> Int {
        let length = (unit == 0x0D && following == 0x0A) ? 2 : 1
        let end = absoluteOffset + length
        let terminator: UInt16 = length == 2 ? 0x0A : unit
        emit(end - lineStart, terminator)
        lineStart = end
        lastTerminatorUnit = terminator
        return length
    }
}

extension NSString {
    /// Appends the UTF-16 length (content plus terminator) of every line in the receiver to `lengths`, in
    /// document order, splitting exactly where `getLineStart(_:end:contentsEnd:for:)` would.
    ///
    /// - Parameter windowUnits: Units fetched per `getCharacters(_:range:)` call. Exposed for tests, which use
    ///   tiny windows to exercise terminators that straddle window boundaries.
    /// - Returns: The final code unit of the last line terminator if the receiver ends with one, `nil` if it
    ///   is empty or ends mid-line. Callers use this to decide whether to model a trailing empty line.
    @discardableResult
    func scanLineLengths(
        into lengths: inout [Int],
        windowUnits: Int = UTF16LineScanner.defaultWindowUnits
    ) -> UInt16? {
        let total = length
        guard total > 0 else { return nil }
        var scanner = UTF16LineScanner()
        // Emitted lengths land in scratch and are flushed with one bulk append per window, so the hot
        // emit is a plain store. Every emit consumes at least one unit of the window, so a window's
        // worth of slots always suffices.
        let scratch = UnsafeMutablePointer<Int>.allocate(capacity: min(windowUnits, total))
        defer { scratch.deallocate() }

        withUTF16Windows(in: NSRange(location: 0, length: total), windowUnits: windowUnits) { units, base, count, next in
            var emitted = 0
            scanner.scan(units, base: base, count: count, next: next) { lineLength, _ in
                scratch[emitted] = lineLength
                emitted += 1
            }
            lengths.append(contentsOf: UnsafeBufferPointer(start: scratch, count: emitted))
        }
        return scanner.finish(totalLength: total) { lineLength, _ in lengths.append(lineLength) }
    }

    /// Visits every line of `range` in order, splitting exactly where `getLineStart(_:end:contentsEnd:for:)`
    /// would. Nothing is copied beyond one window of code units at a time, so this is the right tool for the
    /// edit path: a single-character insert reads two units.
    ///
    /// - Parameter body: Receives each line's UTF-16 length (content plus terminator) and the final code unit
    ///   of its terminator (LF for a CR LF pair), or 0 for an unterminated final line.
    func forEachLine(
        in range: NSRange,
        windowUnits: Int = UTF16LineScanner.defaultWindowUnits,
        _ body: (_ length: Int, _ terminator: UInt16) -> Void
    ) {
        guard range.length > 0 else { return }
        var scanner = UTF16LineScanner()
        withUTF16Windows(in: range, windowUnits: windowUnits) { units, base, count, next in
            scanner.scan(units, base: base, count: count, next: next, emit: body)
        }
        _ = scanner.finish(totalLength: range.length, emit: body)
    }

    /// Feeds the UTF-16 units of `range` to `body` in windows of at most `windowUnits`, with `base` relative
    /// to `range.location` and `next` the unit following the window when one exists.
    ///
    /// Zero-copy when the backing store is already contiguous UTF-16. An `NSTextStorage` never is (its
    /// `NSBigMutableString` is a gap buffer), but plain `NSString`s frequently are.
    private func withUTF16Windows(
        in range: NSRange,
        windowUnits: Int,
        _ body: (_ units: UnsafePointer<UInt16>, _ base: Int, _ count: Int, _ next: UInt16?) -> Void
    ) {
        precondition(windowUnits > 0, "windowUnits must be positive")
        let total = range.length
        let contiguous = CFStringGetCharactersPtr(self as CFString)
        // Never larger than the range: a keystroke should not allocate a 32KB window.
        let windowCapacity = min(windowUnits, total)
        let window: UnsafeMutablePointer<UInt16>? = contiguous == nil
            ? .allocate(capacity: windowCapacity + 1) // +1: a CR on the last position needs to see its LF.
            : nil
        defer { window?.deallocate() }

        var base = 0
        while base < total {
            let count = min(windowCapacity, total - base)
            let hasNext = base + count < total
            let units: UnsafePointer<UInt16>
            if let contiguous {
                units = contiguous + range.location + base
            } else if let window {
                let fetch = NSRange(location: range.location + base, length: count + (hasNext ? 1 : 0))
                getCharacters(window, range: fetch)
                units = UnsafePointer(window)
            } else {
                preconditionFailure("unreachable: a window buffer exists whenever the string is not contiguous")
            }
            body(units, base, count, hasNext ? units[count] : nil)
            base += count
        }
    }
}
