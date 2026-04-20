//
//  TextLineStorage+Node.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 6/25/23.
//

import Foundation

// MARK: - Arena-backed node storage
//
// Nodes live in a single raw `UnsafeMutablePointer` buffer owned by `TextLineStorage`.
// Parent/left/right are 32-bit indices (`NodeHandle`) into that buffer, not class
// references.
//
// The subscript uses `unsafeAddress`/`unsafeMutableAddress` addressors so
// `self[h].field` projects directly to the field and does NOT copy the ~72-byte node
// on every read. A by-value subscript would cost 72 bytes per tree-level; with the
// addressor we only load the fields we touch.
//
// `Int32.min` is the nil handle sentinel. Freed slots go on `freeList` and are reused
// on the next `allocNode`; we don't deinitialize on free — the slot keeps its old
// `Data` until assignment drops it on reuse or `removeAll`/`deinit` tears it down.

extension TextLineStorage {
    @usableFromInline
    typealias NodeHandle = Int32

    @inlinable
    static var nilHandle: NodeHandle { Int32.min }

    @usableFromInline
    enum Color: UInt8 {
        case red
        case black
    }

    /// A tree node. Value type — lives in `TextLineStorage.nodesPtr`.
    ///
    /// Fields are laid out with the hot traversal metadata first to improve packing.
    /// Size for `Data == TextLine` is ~72 bytes, comfortably small enough to prefetch.
    @usableFromInline
    struct Node<NodeData: Identifiable> {
        // Hot traversal metadata (read on every tree walk)
        @usableFromInline var leftSubtreeOffset: Int
        @usableFromInline var leftSubtreeHeight: CGFloat
        @usableFromInline var leftSubtreeCount: Int
        @usableFromInline var length: Int
        @usableFromInline var height: CGFloat
        @usableFromInline var left: NodeHandle
        @usableFromInline var right: NodeHandle
        @usableFromInline var parent: NodeHandle
        @usableFromInline var color: Color
        @usableFromInline var data: NodeData

        @inlinable
        init(
            length: Int,
            data: NodeData,
            leftSubtreeOffset: Int,
            leftSubtreeHeight: CGFloat,
            leftSubtreeCount: Int,
            height: CGFloat,
            left: NodeHandle = Int32.min,
            right: NodeHandle = Int32.min,
            parent: NodeHandle = Int32.min,
            color: Color
        ) {
            self.length = length
            self.data = data
            self.leftSubtreeOffset = leftSubtreeOffset
            self.leftSubtreeHeight = leftSubtreeHeight
            self.leftSubtreeCount = leftSubtreeCount
            self.height = height
            self.left = left
            self.right = right
            self.parent = parent
            self.color = color
        }

        @inlinable
        init(length: Int, data: NodeData, height: CGFloat) {
            self.init(
                length: length,
                data: data,
                leftSubtreeOffset: 0,
                leftSubtreeHeight: 0.0,
                leftSubtreeCount: 0,
                height: height,
                color: .black
            )
        }
    }
}

// MARK: - Arena / handle access

extension TextLineStorage {
    /// Access a node by handle. Addressor-based — `self[h].field` projects directly to
    /// the field with no copy of the 72-byte `Node`. Preconditions: handle refers to a
    /// live slot (not `Int32.min`, not currently in the free list).
    @inlinable
    subscript(_ handle: NodeHandle) -> Node<Data> {
        @_transparent unsafeAddress {
            return UnsafePointer(nodesPtr.advanced(by: Int(handle)))
        }
        @_transparent unsafeMutableAddress {
            return nodesPtr.advanced(by: Int(handle))
        }
    }

    /// Safe read — returns nil for the nil sentinel. Copies the node by value; only use
    /// for test/inspection paths.
    @inlinable
    func nodeOrNil(_ handle: NodeHandle) -> Node<Data>? {
        guard handle != Int32.min else { return nil }
        return nodesPtr.advanced(by: Int(handle)).pointee
    }

    /// Ensure the arena can hold at least `required` slots. Grows geometrically.
    @inlinable
    func ensureNodeCapacity(_ required: Int) {
        guard required > nodesCapacity else { return }
        let newCap = Swift.max(required, Swift.max(16, nodesCapacity * 2))
        let newPtr = UnsafeMutablePointer<Node<Data>>.allocate(capacity: newCap)
        if nodesCount > 0 {
            newPtr.moveInitialize(from: nodesPtr, count: nodesCount)
        }
        nodesPtr.deallocate()
        nodesPtr = newPtr
        nodesCapacity = newCap
    }

    /// Allocate a new node in the arena. Reuses a freed slot when available.
    @inlinable
    func allocNode(
        length: Int,
        data: Data,
        height: CGFloat,
        leftSubtreeOffset: Int = 0,
        leftSubtreeHeight: CGFloat = 0,
        leftSubtreeCount: Int = 0,
        color: Color
    ) -> NodeHandle {
        let node = Node<Data>(
            length: length,
            data: data,
            leftSubtreeOffset: leftSubtreeOffset,
            leftSubtreeHeight: leftSubtreeHeight,
            leftSubtreeCount: leftSubtreeCount,
            height: height,
            color: color
        )
        if let reused = freeList.popLast() {
            // Slot is still initialized (we don't deinitialize on free); assignment
            // destroys the old value and stores the new one.
            nodesPtr.advanced(by: Int(reused)).pointee = node
            return reused
        }
        ensureNodeCapacity(nodesCount + 1)
        nodesPtr.advanced(by: nodesCount).initialize(to: node)
        let handle = NodeHandle(nodesCount)
        nodesCount += 1
        return handle
    }

    /// Return a node's slot to the free list. The slot's `Data` reference is kept alive
    /// until the slot is reused (assignment drops it) or the storage is cleared.
    @inlinable
    func freeNode(_ handle: NodeHandle) {
        freeList.append(handle)
    }

    /// For tests: read-only node view.
    @usableFromInline
    func node(for handle: NodeHandle) -> Node<Data>? {
        nodeOrNil(handle)
    }
}

// MARK: - Test-friendly navigation
//
// `NodeRef` wraps `(storage, handle)` so tests can chain `.root?.right?.left?.length`
// the same way they did when nodes were classes. This is `@usableFromInline` rather
// than `public` — the production layout path goes through handles directly and should
// never allocate these wrappers.

extension TextLineStorage {
    @usableFromInline
    struct NodeRef {
        @usableFromInline let storage: TextLineStorage<Data>
        @usableFromInline let handle: NodeHandle

        @usableFromInline
        init(storage: TextLineStorage<Data>, handle: NodeHandle) {
            self.storage = storage
            self.handle = handle
        }

        @usableFromInline var left: NodeRef? {
            let h = storage[handle].left
            return h == Int32.min ? nil : NodeRef(storage: storage, handle: h)
        }

        @usableFromInline var right: NodeRef? {
            let h = storage[handle].right
            return h == Int32.min ? nil : NodeRef(storage: storage, handle: h)
        }

        @usableFromInline var parent: NodeRef? {
            let h = storage[handle].parent
            return h == Int32.min ? nil : NodeRef(storage: storage, handle: h)
        }

        @usableFromInline var length: Int { storage[handle].length }
        @usableFromInline var height: CGFloat { storage[handle].height }
        @usableFromInline var color: Color { storage[handle].color }
        @usableFromInline var leftSubtreeOffset: Int { storage[handle].leftSubtreeOffset }
        @usableFromInline var leftSubtreeHeight: CGFloat { storage[handle].leftSubtreeHeight }
        @usableFromInline var leftSubtreeCount: Int { storage[handle].leftSubtreeCount }
        @usableFromInline var data: Data { storage[handle].data }
    }

    /// Root node as a chainable reference. `nil` when the tree is empty.
    @usableFromInline
    var root: NodeRef? {
        rootHandle == Int32.min ? nil : NodeRef(storage: self, handle: rootHandle)
    }
}

// MARK: - Tree helpers (handle-based)
//
// All helpers hoist `nodesPtr` into a local `ptr` and traverse with direct pointer
// arithmetic. Using `self[handle].field` here would force the compiler to reload
// `self.nodesPtr` (a class-property load) on every field access inside the loop; the
// hoisted pointer guarantees a single load per call and lets the loop body compile to
// a tight sequence of indexed loads.

extension TextLineStorage {
    @inlinable
    func isRightChild(_ handle: NodeHandle) -> Bool {
        let ptr = nodesPtr
        let parent = (ptr + Int(handle)).pointee.parent
        guard parent != Int32.min else { return false }
        return (ptr + Int(parent)).pointee.right == handle
    }

    @inlinable
    func isLeftChild(_ handle: NodeHandle) -> Bool {
        let ptr = nodesPtr
        let parent = (ptr + Int(handle)).pointee.parent
        guard parent != Int32.min else { return false }
        return (ptr + Int(parent)).pointee.left == handle
    }

    /// Transplants one node with another. Meta (left/parent updates at parent nodes)
    /// is left to the caller — matches the original behavior.
    @inlinable
    func transplant(_ nodeU: NodeHandle, with nodeV: NodeHandle) {
        let ptr = nodesPtr
        let parentU = (ptr + Int(nodeU)).pointee.parent
        if parentU == Int32.min {
            rootHandle = nodeV
        } else {
            let parentNode = ptr + Int(parentU)
            if parentNode.pointee.left == nodeU {
                parentNode.pointee.left = nodeV
            } else {
                parentNode.pointee.right = nodeV
            }
        }
        if nodeV != Int32.min {
            (ptr + Int(nodeV)).pointee.parent = parentU
        }
    }

    /// Sibling of `handle` (nil if no parent, or parent has only this child).
    @inlinable
    func sibling(_ handle: NodeHandle) -> NodeHandle {
        let ptr = nodesPtr
        let parent = (ptr + Int(handle)).pointee.parent
        guard parent != Int32.min else { return Int32.min }
        let parentNode = ptr + Int(parent)
        let left = parentNode.pointee.left
        if left == handle {
            return parentNode.pointee.right
        } else {
            return left
        }
    }

    /// Leftmost descendant of `handle` (inclusive). Iterative — avoids deep recursion
    /// blowing the stack on long left spines.
    @inlinable
    func minimum(_ handle: NodeHandle) -> NodeHandle {
        let ptr = nodesPtr
        var current = handle
        while true {
            let left = (ptr + Int(current)).pointee.left
            if left == Int32.min { return current }
            current = left
        }
    }

    /// Rightmost descendant of `handle` (inclusive). Iterative.
    @inlinable
    func maximum(_ handle: NodeHandle) -> NodeHandle {
        let ptr = nodesPtr
        var current = handle
        while true {
            let right = (ptr + Int(current)).pointee.right
            if right == Int32.min { return current }
            current = right
        }
    }

    /// In-order successor. Iterative.
    @inlinable
    func successor(_ handle: NodeHandle) -> NodeHandle {
        let ptr = nodesPtr
        let right = (ptr + Int(handle)).pointee.right
        if right != Int32.min {
            return minimum(right)
        }
        var current = handle
        var parent = (ptr + Int(current)).pointee.parent
        while parent != Int32.min && (ptr + Int(parent)).pointee.right == current {
            current = parent
            parent = (ptr + Int(current)).pointee.parent
        }
        return parent
    }
}
