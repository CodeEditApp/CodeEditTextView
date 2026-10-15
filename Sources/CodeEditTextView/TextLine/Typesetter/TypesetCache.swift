//
//  TypesetCache.swift
//  CodeEditTextView
//
//  LRU cache of typeset results (CTLines + fragment metrics) so unedited lines do not re-typeset
//  across layout passes. CTTypesetter cannot be reset, so we cache the *output* of typesetting:
//  a description of each fragment that lets us rebuild fresh `LineFragment` instances cheaply
//  (since LineFragment.documentRange is mutated downstream and instances therefore can't be shared).
//

import AppKit
import CoreText

/// One cached fragment within a typeset result. CTLine is immutable / thread-safe so it can be reused freely.
struct CachedFragment {
    let ctLine: CTLine
    let length: Int
    let width: CGFloat
    let height: CGFloat
    let descent: CGFloat
    /// The line's glyph ink, measured when it was typeset (see ``LineInk``).
    let ink: LineInk
}

struct CachedTypesetResult {
    let fragments: [CachedFragment]
    let maxHeight: CGFloat
}

/// Cache key. The key is content-addressed: it owns an immutable snapshot of the full attributed
/// string, and equality compares actual characters and every attribute run (via `isEqual(to:)`),
/// never hashes alone. Two distinct lines therefore can never alias, and any content or
/// attribute-only change produces a new key.
///
/// A *probe* key (``probe(_:range:displayData:)``) instead refers to a range of a live attributed
/// string, the document's text storage, without copying it. It only looks entries up and is never
/// stored, so a cache hit costs no `attributedSubstring(from:)`: that substring was most of the
/// ~1.9 µs every typeset of a 90-character line paid, hits included.
struct TypesetCacheKey: Hashable {
    /// The snapshot, or for a probe the live string `range` refers into.
    let string: NSAttributedString
    /// For a probe, the range of `string` the key stands for; nil for a stored snapshot.
    let range: NSRange?
    let maxWidth: CGFloat
    let breakStrategy: LineBreakStrategy
    let lineHeightMultiplier: CGFloat
    private let contentHash: Int

    init(
        string: NSAttributedString,
        range: NSRange? = nil,
        maxWidth: CGFloat,
        breakStrategy: LineBreakStrategy,
        lineHeightMultiplier: CGFloat,
        contentHash: Int
    ) {
        self.string = string
        self.range = range
        self.maxWidth = maxWidth
        self.breakStrategy = breakStrategy
        self.lineHeightMultiplier = lineHeightMultiplier
        self.contentHash = contentHash
    }

    static func == (lhs: TypesetCacheKey, rhs: TypesetCacheKey) -> Bool {
        guard lhs.contentHash == rhs.contentHash
            && lhs.maxWidth == rhs.maxWidth
            && lhs.breakStrategy == rhs.breakStrategy
            && lhs.lineHeightMultiplier == rhs.lineHeightMultiplier else {
            return false
        }
        switch (lhs.range, rhs.range) {
        case (nil, nil):
            return lhs.string.isEqual(to: rhs.string)
        case (nil, let range?):
            return snapshot(lhs.string, matches: rhs.string, in: range)
        case (let range?, nil):
            return snapshot(rhs.string, matches: lhs.string, in: range)
        case (let lhsRange?, let rhsRange?):
            let lhsString = lhs.string.attributedSubstring(from: lhsRange)
            return lhsString.isEqual(to: rhs.string.attributedSubstring(from: rhsRange))
        }
    }

    /// Whether `snapshot` holds exactly the characters and attributes `source` holds in `range` - what
    /// `isEqual(to:)` would answer for `source`'s substring, without creating that substring.
    private static func snapshot(
        _ snapshot: NSAttributedString,
        matches source: NSAttributedString,
        in range: NSRange
    ) -> Bool {
        let length = range.length
        guard snapshot.length == length, range.max <= source.length else { return false }
        guard length > 0 else { return true }
        let charactersMatch = withUnsafeTemporaryAllocation(of: UInt16.self, capacity: length * 2) { buffer in
            guard let base = buffer.baseAddress else { return false }
            (snapshot.string as NSString).getCharacters(base, range: NSRange(location: 0, length: length))
            (source.string as NSString).getCharacters(base + length, range: range)
            return memcmp(base, base + length, length * MemoryLayout<UInt16>.stride) == 0
        }
        guard charactersMatch else { return false }

        // Attributes, one maximal run at a time. Core Foundation calls: the Swift overlay would bridge every
        // attribute dictionary.
        let snapshotCF = snapshot as CFAttributedString
        let sourceCF = source as CFAttributedString
        let sourceRange = CFRange(location: range.location, length: length)
        var offset = 0
        while offset < length {
            var snapshotRun = CFRange()
            var sourceRun = CFRange()
            let snapshotAttributes = CFAttributedStringGetAttributesAndLongestEffectiveRange(
                snapshotCF, offset, CFRange(location: 0, length: length), &snapshotRun
            )
            let sourceAttributes = CFAttributedStringGetAttributesAndLongestEffectiveRange(
                sourceCF, range.location + offset, sourceRange, &sourceRun
            )
            let snapshotEnd = snapshotRun.location + snapshotRun.length
            guard snapshotEnd == sourceRun.location + sourceRun.length - range.location,
                  CFEqual(snapshotAttributes, sourceAttributes) else {
                return false
            }
            offset = snapshotEnd
        }
        return true
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(contentHash)
        hasher.combine(maxWidth)
        hasher.combine(breakStrategy)
        hasher.combine(lineHeightMultiplier)
    }
}

/// Process-wide LRU. The text view typically holds a single layout manager but minimaps + multiple
/// editors share Core Text work; a global pool maximizes reuse without coordination.
final class TypesetCache: @unchecked Sendable {
    static let shared = TypesetCache(capacity: 512)

    private struct Node {
        var key: TypesetCacheKey
        var value: CachedTypesetResult
        var prev: Int
        var next: Int
    }

    private let capacity: Int
    private var nodes: ContiguousArray<Node> = []
    private var lookup: [TypesetCacheKey: Int] = [:]
    private var head: Int = -1 // most recently used
    private var tail: Int = -1 // least recently used
    private var freeList: [Int] = []
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = capacity
        nodes.reserveCapacity(capacity)
        lookup.reserveCapacity(capacity)
    }

    func get(_ key: TypesetCacheKey) -> CachedTypesetResult? {
        lock.lock()
        defer { lock.unlock() }
        guard let idx = lookup[key] else { return nil }
        moveToHead(idx)
        return nodes[idx].value
    }

    func set(_ key: TypesetCacheKey, _ value: CachedTypesetResult) {
        lock.lock()
        defer { lock.unlock() }
        if let idx = lookup[key] {
            nodes[idx].value = value
            moveToHead(idx)
            return
        }
        let idx: Int
        if lookup.count >= capacity, tail != -1 {
            // Evict LRU
            idx = tail
            lookup.removeValue(forKey: nodes[idx].key)
            removeFromList(idx)
            nodes[idx].key = key
            nodes[idx].value = value
        } else if let free = freeList.popLast() {
            idx = free
            nodes[idx].key = key
            nodes[idx].value = value
            nodes[idx].prev = -1
            nodes[idx].next = -1
        } else {
            idx = nodes.count
            nodes.append(Node(key: key, value: value, prev: -1, next: -1))
        }
        lookup[key] = idx
        addToHead(idx)
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        nodes.removeAll(keepingCapacity: true)
        lookup.removeAll(keepingCapacity: true)
        freeList.removeAll(keepingCapacity: true)
        head = -1
        tail = -1
    }

    // MARK: - LRU list manipulation (indices into `nodes`)

    private func addToHead(_ idx: Int) {
        nodes[idx].prev = -1
        nodes[idx].next = head
        if head != -1 { nodes[head].prev = idx }
        head = idx
        if tail == -1 { tail = idx }
    }

    private func removeFromList(_ idx: Int) {
        let p = nodes[idx].prev
        let n = nodes[idx].next
        if p != -1 { nodes[p].next = n } else { head = n }
        if n != -1 { nodes[n].prev = p } else { tail = p }
        nodes[idx].prev = -1
        nodes[idx].next = -1
    }

    private func moveToHead(_ idx: Int) {
        if head == idx { return }
        removeFromList(idx)
        addToHead(idx)
    }
}

// MARK: - Key derivation

extension TypesetCacheKey {
    /// Build a key from an attributed substring + display data. Snapshots the string so later
    /// mutation of a caller-owned mutable string cannot corrupt the cache.
    static func make(
        string: NSAttributedString,
        displayData: TextLine.DisplayData
    ) -> TypesetCacheKey {
        // `copy()` is free for immutable instances (returns self) and only pays for a real copy
        // when handed an NSMutableAttributedString.
        let snapshot = string.copy() as? NSAttributedString ?? NSAttributedString(attributedString: string)
        // Hash the full character content; attribute differences only affect bucket placement,
        // equality still compares every run.
        return TypesetCacheKey(
            string: snapshot,
            maxWidth: displayData.maxWidth,
            breakStrategy: displayData.breakStrategy,
            lineHeightMultiplier: displayData.lineHeightMultiplier,
            contentHash: contentHash(
                of: snapshot.string as NSString,
                in: NSRange(location: 0, length: snapshot.length)
            )
        )
    }

    /// A lookup-only key for `range` of `source` (the document's text storage), equal to the key
    /// ``make(string:displayData:)`` builds from that range's substring. Copies nothing.
    static func probe(
        _ source: NSAttributedString,
        range: NSRange,
        displayData: TextLine.DisplayData
    ) -> TypesetCacheKey {
        TypesetCacheKey(
            string: source,
            range: range,
            maxWidth: displayData.maxWidth,
            breakStrategy: displayData.breakStrategy,
            lineHeightMultiplier: displayData.lineHeightMultiplier,
            contentHash: contentHash(of: source.string as NSString, in: range)
        )
    }

    /// Hashes the raw UTF-16 code units of `range`, the units `isEqual(to:)` compares. Hashing the
    /// characters as a Swift `String` bridged them and hashed with Unicode normalization.
    private static func contentHash(of characters: NSString, in range: NSRange) -> Int {
        var hasher = Hasher()
        hasher.combine(range.length)
        if range.length > 0 {
            withUnsafeTemporaryAllocation(of: UInt16.self, capacity: range.length) { buffer in
                guard let base = buffer.baseAddress else { return }
                characters.getCharacters(base, range: range)
                hasher.combine(bytes: UnsafeRawBufferPointer(buffer))
            }
        }
        return hasher.finalize()
    }
}
