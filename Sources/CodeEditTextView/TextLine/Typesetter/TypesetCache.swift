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
}

struct CachedTypesetResult {
    let fragments: [CachedFragment]
    let maxHeight: CGFloat
}

/// Cache key. The key is content-addressed: it owns an immutable snapshot of the full attributed
/// string, and equality compares actual characters and every attribute run (via `isEqual(to:)`),
/// never hashes alone. Two distinct lines therefore can never alias, and any content or
/// attribute-only change produces a new key.
struct TypesetCacheKey: Hashable {
    let string: NSAttributedString
    let maxWidth: CGFloat
    let breakStrategy: LineBreakStrategy
    let lineHeightMultiplier: CGFloat
    private let contentHash: Int

    init(
        string: NSAttributedString,
        maxWidth: CGFloat,
        breakStrategy: LineBreakStrategy,
        lineHeightMultiplier: CGFloat,
        contentHash: Int
    ) {
        self.string = string
        self.maxWidth = maxWidth
        self.breakStrategy = breakStrategy
        self.lineHeightMultiplier = lineHeightMultiplier
        self.contentHash = contentHash
    }

    static func == (lhs: TypesetCacheKey, rhs: TypesetCacheKey) -> Bool {
        lhs.contentHash == rhs.contentHash
            && lhs.maxWidth == rhs.maxWidth
            && lhs.breakStrategy == rhs.breakStrategy
            && lhs.lineHeightMultiplier == rhs.lineHeightMultiplier
            && lhs.string.isEqual(to: rhs.string)
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
        var hasher = Hasher()
        hasher.combine(snapshot.string)
        return TypesetCacheKey(
            string: snapshot,
            maxWidth: displayData.maxWidth,
            breakStrategy: displayData.breakStrategy,
            lineHeightMultiplier: displayData.lineHeightMultiplier,
            contentHash: hasher.finalize()
        )
    }
}
