//
//  LineTerminatorScanner.swift
//  CodeEditTextView
//

import Foundation

/// Scans UTF-16 code units for line terminators.
///
/// Terminators are U+000A (LINE FEED) and U+000D (CARRIAGE RETURN); CR LF is a single two-unit terminator. These are
/// the line endings `LineEnding` models and the ones the edit path splits at, so a document opens with the same line
/// structure any sequence of edits produces. Foundation's `getLineStart(_:end:contentsEnd:for:)` also ends lines at
/// U+0085 (NEXT LINE), U+2028 (LINE SEPARATOR) and U+2029 (PARAGRAPH SEPARATOR); here those stay inside their line,
/// as in most code editors (Core Text still breaks the line's layout at U+2028 and U+2029). U+000B and U+000C are
/// not terminators either. `LineTerminatorScannerTests` verifies this for every code unit.
///
/// The scanner is stateful so a document can be fed in windows; a CR LF pair straddling a window
/// boundary is handled through the `next` lookahead unit.
struct UTF16LineScanner {
    /// Code units per window when a string is fed through ``NSString/scanLineLengths(into:windowUnits:)``.
    /// 16K units is 32KB, resident in L1 on both performance and efficiency cores.
    static let defaultWindowUnits = 16_384

#if DEBUG
    /// Debug builds split lines with Foundation's `getLineStart(_:end:contentsEnd:for:)` (rejoining the lines it ends at
    /// NEL, LS and PS) instead of the SIMD kernels.
    ///
    /// The kernels are generic `SIMD16` code, which runs 125-350x slower unoptimized: every lane operation becomes an
    /// unspecialized call. Apps build their SwiftPM dependencies at `-Onone` in Debug, so without this a debug build
    /// of the editor spent most of a multi-cursor keystroke, and up to a second opening a 2 MB file, in the scanner.
    /// Foundation's implementation is optimized even then. Release builds have no switch and always use the kernels.
    ///
    /// Tests set this to `false` to exercise the kernels in debug builds too.
    nonisolated(unsafe) static var usesFoundationFallback = true
#endif

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
        // Prefilter, a wrapping subtract plus one unsigned compare: 0x0A...0x0D (LF, VT, FF, CR - tab is excluded
        // so indentation does not defeat the filter).
        let controlBias = SIMD16<UInt16>(repeating: 0x0A)
        let controlSpan = SIMD16<UInt16>(repeating: 4)

        while index &+ 16 <= count {
            let chunk = UnsafeRawPointer(buffer + index).loadUnaligned(as: SIMD16<UInt16>.self)
            if !any((chunk &- controlBias) .< controlSpan) {
                index &+= 16
                continue
            }
            let hits = (chunk .== lineFeed) .| (chunk .== carriageReturn)
            // Movemask: one bit per hit lane, so each terminator is visited directly instead of
            // re-testing all 16 units one at a time.
            var bits = lineTerminatorLaneBits(hits)
            let blockStart = index
            while bits != 0 {
                let offset = blockStart &+ bits.trailingZeroBitCount
                bits &= bits &- 1
                // An LF that completed a preceding CR LF pair has already been consumed.
                if offset < index {
                    continue
                }
                let following: UInt16? = offset &+ 1 < count ? buffer[offset &+ 1] : next
                index = offset &+ consumeTerminator(buffer[offset], at: base &+ offset, following: following, emit: emit)
            }
            index = max(index, blockStart &+ 16)
        }

        // Scalar tail: fewer than 16 units remain in this window.
        while index < count {
            let unit = buffer[index]
            if unit == 0x0A || unit == 0x0D {
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
    /// document order, splitting at LF, CR and CR LF (see ``UTF16LineScanner``).
    ///
    /// - Parameter windowUnits: Units fetched per `getCharacters(_:range:)` call. Exposed for tests, which use
    ///   tiny windows to exercise terminators that straddle window boundaries.
    /// - Returns: The final code unit of the last line terminator if the receiver ends with one, `nil` if it
    ///   is empty or ends mid-line. Callers use this to decide whether to model a trailing empty line.
    ///
    /// This is the document-open path, so it uses a throughput kernel (``scanLineStarts(_:count:base:next:into:)``)
    /// rather than ``UTF16LineScanner``, whose per-call setup suits the few units an edit scans.
    @discardableResult
    func scanLineLengths(
        into lengths: inout [Int],
        windowUnits: Int = UTF16LineScanner.defaultWindowUnits
    ) -> UInt16? {
        let total = length
        guard total > 0 else { return nil }
#if DEBUG
        if UTF16LineScanner.usesFoundationFallback {
            return foundationScanLineLengths(into: &lengths)
        }
#endif
        // Line starts land in scratch and are turned into lengths in place, then flushed with one bulk append per
        // window. A window emits at most one start per unit; the kernel's unconditional stores may write up to
        // 64 slots past the last start.
        let scratch = UnsafeMutablePointer<Int>.allocate(capacity: min(windowUnits, total) + 64)
        defer { scratch.deallocate() }

        var lastStart = 0
        withUTF16Windows(in: NSRange(location: 0, length: total), windowUnits: windowUnits) { units, base, count, next in
            let emitted = scanLineStarts(units, count: count, base: base, next: next, into: scratch)
            var previous = lastStart
            for slot in 0..<emitted {
                let start = scratch[slot]
                scratch[slot] = start &- previous
                previous = start
            }
            lastStart = previous
            lengths.append(contentsOf: UnsafeBufferPointer(start: scratch, count: emitted))
        }
        if lastStart < total {
            lengths.append(total - lastStart)
            return nil
        }
        return character(at: total - 1) // The last terminator's final unit: LF for CR LF.
    }

    /// Visits every line of `range` in order, splitting at LF, CR and CR LF (see ``UTF16LineScanner``). Nothing is
    /// copied beyond one window of code units at a time, so this is the right tool for the edit path: a
    /// single-character insert reads two units.
    ///
    /// - Parameter body: Receives each line's UTF-16 length (content plus terminator) and the final code unit
    ///   of its terminator (LF for a CR LF pair), or 0 for an unterminated final line.
    func forEachLine(
        in range: NSRange,
        windowUnits: Int = UTF16LineScanner.defaultWindowUnits,
        _ body: (_ length: Int, _ terminator: UInt16) -> Void
    ) {
        guard range.length > 0 else { return }
#if DEBUG
        if UTF16LineScanner.usesFoundationFallback {
            foundationForEachLine(in: range, body)
            return
        }
#endif
        var scanner = UTF16LineScanner()
        withUTF16Windows(in: range, windowUnits: windowUnits) { units, base, count, next in
            scanner.scan(units, base: base, count: count, next: next, emit: body)
        }
        _ = scanner.finish(totalLength: range.length, emit: body)
    }

#if DEBUG
    /// ``scanLineLengths(into:windowUnits:)`` on Foundation's line splitting; see
    /// ``UTF16LineScanner/usesFoundationFallback``.
    private func foundationScanLineLengths(into lengths: inout [Int]) -> UInt16? {
        var lastTerminator: UInt16?
        foundationForEachLine(in: NSRange(location: 0, length: length)) { lineLength, terminator in
            lengths.append(lineLength)
            lastTerminator = terminator == 0 ? nil : terminator
        }
        return lastTerminator
    }

    /// ``forEachLine(in:windowUnits:_:)`` on Foundation's line splitting; see
    /// ``UTF16LineScanner/usesFoundationFallback``.
    ///
    /// Like the scanner, sees nothing past `range`: a line is clipped at the range's end, so a CR there is a
    /// terminator even when an LF follows outside the range. Foundation also ends lines at NEL, LS and PS; those
    /// pieces are joined back into the line that continues past them.
    private func foundationForEachLine(in range: NSRange, _ body: (_ length: Int, _ terminator: UInt16) -> Void) {
        let limit = range.location + range.length
        var lineStart = range.location
        var location = range.location
        var end = 0
        while location < limit {
            getLineStart(nil, end: &end, contentsEnd: nil, for: NSRange(location: location, length: 0))
            end = min(end, limit)
            location = end
            let last = character(at: end - 1)
            if last == 0x0A || last == 0x0D {
                body(end - lineStart, last)
                lineStart = end
            }
        }
        if lineStart < limit {
            body(limit - lineStart, 0)
        }
    }
#endif

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

// MARK: - Bulk scan kernel

/// Bit `i` set for lane `i`. The weights are disjoint bits, so OR-folding the masked lanes equals their sum.
@inline(__always)
private var laneWeights: SIMD16<UInt16> {
    SIMD16<UInt16>(1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768)
}

/// Movemask for 16 lanes: bit `i` is set when lane `i` of `mask` is true.
///
/// Folds through 64-bit general-purpose registers. `replacing(with:where:).wrappedSum()` is scalarized by the
/// compiler into 16 lane extracts plus ~20 scalar ops, or called out of line.
@inline(__always)
func lineTerminatorLaneBits(_ mask: SIMDMask<SIMD16<Int16>>) -> UInt64 {
    let weighted = unsafeBitCast(mask, to: SIMD16<UInt16>.self) & laneWeights
    let words = unsafeBitCast(weighted, to: SIMD4<UInt64>.self)
    var folded = (words[0] | words[1]) | (words[2] | words[3])
    folded |= folded &>> 32
    folded |= folded &>> 16
    return folded & 0xFFFF
}

/// OR of every lane, folded to 64 bits; zero iff every lane is zero.
@inline(__always)
private func orFold(_ vector: SIMD16<UInt16>) -> UInt64 {
    let words = unsafeBitCast(vector, to: SIMD4<UInt64>.self)
    return (words[0] | words[1]) | (words[2] | words[3])
}

/// Terminator bits for the 16 units at `pointer`, which must be readable through `pointer[16]`: the unit after
/// the block decides whether a CR in the last lane is half of a CR LF pair. A CR followed by LF is not a hit;
/// its LF is.
@inline(__always)
private func terminatorBits16(_ pointer: UnsafeRawPointer) -> UInt64 {
    let units = pointer.loadUnaligned(as: SIMD16<UInt16>.self)
    let following = pointer.loadUnaligned(fromByteOffset: 2, as: SIMD16<UInt16>.self)
    let lineFeed = SIMD16<UInt16>(repeating: 0x0A)
    let hits = (units .== lineFeed) .| ((units .== SIMD16<UInt16>(repeating: 0x0D)) .& .!(following .== lineFeed))
    return lineTerminatorLaneBits(hits)
}

/// Writes `base + 1 + offset` for every set bit of `bits` into `out[count...]`. Four unconditional stores cover the
/// common case without a data-dependent branch per terminator; only blocks with more than four hits loop. The
/// unconditional stores may write up to four slots past the final count.
@inline(__always)
private func storeLineStarts(
    _ bits: UInt64,
    base: Int,
    _ out: UnsafeMutablePointer<Int>,
    _ count: inout Int
) {
    var remaining = bits
    let hits = remaining.nonzeroBitCount
    out[count] = base &+ remaining.trailingZeroBitCount
    remaining &= remaining &- 1
    out[count &+ 1] = base &+ remaining.trailingZeroBitCount
    remaining &= remaining &- 1
    out[count &+ 2] = base &+ remaining.trailingZeroBitCount
    remaining &= remaining &- 1
    out[count &+ 3] = base &+ remaining.trailingZeroBitCount
    remaining &= remaining &- 1
    if hits > 4 {
        var slot = count &+ 4
        while remaining != 0 {
            out[slot] = base &+ remaining.trailingZeroBitCount
            slot &+= 1
            remaining &= remaining &- 1
        }
    }
    count &+= hits
}

/// Writes the absolute start offset of every line that begins inside `units[0 ..< count]` (that is, the offset just
/// past each terminator) to `out`, with the semantics of ``UTF16LineScanner``. Returns the number written.
///
/// Works in 64-unit blocks with one 64-bit hit mask each. Blocks with no unit in 0x0A...0x0D (the inside of long
/// lines, whatever the script) are skipped after one compare; the rest test LF and CR. The tail of fewer than 65 units
/// is scalar, and `next` (the unit after the window, if any) decides a CR in the last position.
///
/// - Parameter out: Room for `count + 64` entries.
@inline(__always)
func scanLineStarts(
    _ units: UnsafePointer<UInt16>,
    count: Int,
    base: Int,
    next: UInt16?,
    into out: UnsafeMutablePointer<Int>
) -> Int {
    let raw = UnsafeRawPointer(units)
    var emitted = 0
    var index = 0
    let controlBias = SIMD16<UInt16>(repeating: 0x0A)
    let controlSpan = SIMD16<UInt16>(repeating: 4)
    // A block reads one unit past its end (the CR LF lookahead), so it needs 65 units.
    while index &+ 65 <= count {
        let block = raw + index &* 2
        let v0 = block.loadUnaligned(as: SIMD16<UInt16>.self)
        let v1 = block.loadUnaligned(fromByteOffset: 32, as: SIMD16<UInt16>.self)
        let v2 = block.loadUnaligned(fromByteOffset: 64, as: SIMD16<UInt16>.self)
        let v3 = block.loadUnaligned(fromByteOffset: 96, as: SIMD16<UInt16>.self)
        let candidates = ((v0 &- controlBias) .< controlSpan) .| ((v1 &- controlBias) .< controlSpan)
            .| ((v2 &- controlBias) .< controlSpan) .| ((v3 &- controlBias) .< controlSpan)
        if orFold(unsafeBitCast(candidates, to: SIMD16<UInt16>.self)) == 0 {
            index &+= 64
            continue
        }
        let bits = terminatorBits16(block)
            | terminatorBits16(block + 32) &<< 16
            | terminatorBits16(block + 64) &<< 32
            | terminatorBits16(block + 96) &<< 48
        storeLineStarts(bits, base: base &+ index &+ 1, out, &emitted)
        index &+= 64
    }
    while index < count {
        let unit = units[index]
        if unit == 0x0A || unit == 0x0D {
            let following: UInt16? = index &+ 1 < count ? units[index &+ 1] : next
            if unit != 0x0D || following != 0x0A {
                out[emitted] = base &+ index &+ 1
                emitted &+= 1
            }
        }
        index &+= 1
    }
    return emitted
}
