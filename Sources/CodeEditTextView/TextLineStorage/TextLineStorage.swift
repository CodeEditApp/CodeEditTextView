//
//  TextLayoutLineStorage.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 6/25/23.
//

import Foundation

// swiftlint:disable file_length

// MARK: - Performance notes
//
// `TextLineStorage` is a red-black tree keyed on document offset and index, with an
// auxiliary Y-position metric. It is the hottest data structure in the text engine —
// the layout loop walks it per-frame to find visible lines, selection drawing hits it
// once per selection-fragment, and every edit mutates it.
//
// Nodes live in a raw `UnsafeMutablePointer<Node<Data>>` buffer owned by this class.
// Parent/left/right are 32-bit indices into that buffer, not class references.
//
// Why raw pointer and not `ContiguousArray<Node<Data>>`? Array's subscript getter
// returns by value, so `self[h].field` would copy the whole 72-byte node on every
// read. The subscript in `TextLineStorage+Node.swift` uses
// `unsafeAddress`/`unsafeMutableAddress` addressors over the raw buffer, which project
// directly to the field with no copy.
//
// Hot traversal functions (search, getLine, rotate, fixups) hoist `nodesPtr` into a
// local `ptr` and use `(ptr + Int(h)).pointee.field` directly. This is deliberate:
// without it, every `self[h].field` has to re-load `self.nodesPtr` (a class-property
// load) before the pointer math, and the compiler cannot reliably CSE those loads
// across a loop of 20+ iterations. Writes in the same loops can stay on the subscript
// (`self[h].field = x`) since the `_modify`/mutable-addressor path is already
// in-place and the loss from re-loading `nodesPtr` on a handful of writes is small.
//
// All tree methods take `NodeHandle` (Int32); `Int32.min` is the nil sentinel. Freed
// slots go on `freeList` and are reused on the next `allocNode`. We don't deinitialize
// on free — the slot keeps its `Data` until assignment drops it on reuse or
// `removeAll`/`deinit` tears down the occupied range.

/// Implements a red-black tree for efficiently editing, storing and retrieving lines of text in a document.
public final class TextLineStorage<Data: Identifiable> {
    private enum MetaFixupAction {
        case inserted
        case deleted
        case none
    }

    // MARK: - Arena state

    @usableFromInline
    internal var nodesPtr: UnsafeMutablePointer<Node<Data>>

    @usableFromInline
    internal var nodesCapacity: Int

    @usableFromInline
    internal var nodesCount: Int = 0

    @usableFromInline
    internal var freeList: [NodeHandle] = []

    @usableFromInline
    internal var rootHandle: NodeHandle = Int32.min

    // MARK: - Public state

    /// The number of characters in the storage object.
    private(set) public var length: Int = 0
    /// The number of lines in the storage object
    private(set) public var count: Int = 0

    public var isEmpty: Bool { count == 0 }

    public var height: CGFloat = 0

    public var first: TextLinePosition? {
        guard rootHandle != Int32.min else { return nil }
        let h = minimum(rootHandle)
        let node = nodesPtr + Int(h)
        return TextLinePosition(
            data: node.pointee.data,
            range: NSRange(location: 0, length: node.pointee.length),
            yPos: 0,
            height: node.pointee.height,
            index: 0
        )
    }

    public var last: TextLinePosition? {
        guard rootHandle != Int32.min else { return nil }
        let h = maximum(rootHandle)
        let node = nodesPtr + Int(h)
        return TextLinePosition(
            data: node.pointee.data,
            range: NSRange(location: length - node.pointee.length, length: node.pointee.length),
            yPos: height - node.pointee.height,
            height: node.pointee.height,
            index: count - 1
        )
    }

    @usableFromInline
    var lastNode: NodePosition? {
        guard rootHandle != Int32.min else { return nil }
        let h = maximum(rootHandle)
        let node = nodesPtr + Int(h)
        return NodePosition(
            handle: h,
            data: node.pointee.data,
            length: node.pointee.length,
            height: node.pointee.height,
            yPos: height - node.pointee.height,
            textPos: length - node.pointee.length,
            index: count - 1
        )
    }

    public init() {
        self.nodesCapacity = 16
        self.nodesPtr = UnsafeMutablePointer<Node<Data>>.allocate(capacity: 16)
    }

    deinit {
        if nodesCount > 0 {
            nodesPtr.deinitialize(count: nodesCount)
        }
        nodesPtr.deallocate()
    }

    /// Test-only state injection for tree tests that need a specific hand-crafted shape
    /// the public API can't produce (RB-tree inserts always rebalance). Internal so it
    /// doesn't leak to external consumers; `@testable import` exposes it to test code.
    @usableFromInline
    internal func _unsafeSetCounters(count: Int, length: Int, height: CGFloat) {
        self.count = count
        self.length = length
        self.height = height
    }

    // MARK: - Public Methods

    /// Inserts a new line for the given range.
    /// - Complexity: `O(log n)` where `n` is the number of lines in the storage object.
    public func insert(line: Data, atOffset index: Int, length: Int, height: CGFloat) {
        assert(index >= 0 && index <= self.length, "Invalid index, expected between 0 and \(self.length). Got \(index)")
        defer {
            self.count += 1
            self.length += length
            self.height += height
        }

        // Empty tree — first insert becomes the root.
        guard rootHandle != Int32.min else {
            rootHandle = allocNode(length: length, data: line, height: height, color: .black)
            return
        }

        let inserted = allocNode(length: length, data: line, height: height, color: .red)
        // `allocNode` may have grown the buffer — read `nodesPtr` AFTER it.
        let ptr = nodesPtr

        // Walk down to the correct parent position, tracking the target offset.
        var currentHandle = rootHandle
        var currentOffset = (ptr + Int(rootHandle)).pointee.leftSubtreeOffset
        while true {
            let node = ptr + Int(currentHandle)
            if currentOffset >= index {
                let leftHandle = node.pointee.left
                if leftHandle != Int32.min {
                    currentOffset += (ptr + Int(leftHandle)).pointee.leftSubtreeOffset
                        - node.pointee.leftSubtreeOffset
                    currentHandle = leftHandle
                } else {
                    node.pointee.left = inserted
                    (ptr + Int(inserted)).pointee.parent = currentHandle
                    break
                }
            } else {
                let rightHandle = node.pointee.right
                if rightHandle != Int32.min {
                    currentOffset += node.pointee.length
                        + (ptr + Int(rightHandle)).pointee.leftSubtreeOffset
                    currentHandle = rightHandle
                } else {
                    node.pointee.right = inserted
                    (ptr + Int(inserted)).pointee.parent = currentHandle
                    break
                }
            }
        }

        let insertedNode = ptr + Int(inserted)
        metaFixup(
            startingAt: inserted,
            delta: insertedNode.pointee.length,
            deltaHeight: insertedNode.pointee.height,
            nodeAction: .inserted
        )
        insertFixup(handle: inserted)
    }

    /// Fetches a line for the given offset.
    /// - Complexity: `O(log n)`
    @inlinable
    public func getLine(atOffset offset: Int) -> TextLinePosition? {
        guard let position = search(for: offset) else { return nil }
        return TextLinePosition(position: position)
    }

    /// Fetches a line for the given index.
    /// - Complexity: `O(log n)`
    @inlinable
    public func getLine(atIndex index: Int) -> TextLinePosition? {
        guard let position = search(forIndex: index) else { return nil }
        return TextLinePosition(position: position)
    }

    /// Fetches a line for the given `y` value.
    /// - Complexity: `O(log n)`
    @inlinable
    public func getLine(atPosition posY: CGFloat) -> TextLinePosition? {
        guard posY >= 0 else { return first }
        guard posY < height else {
            return last
        }
        guard let position = search(forYPosition: posY) else { return nil }
        return TextLinePosition(position: position)
    }

    /// Applies a length change at the given index.
    /// - Complexity `O(log n)`.
    public func update(atOffset offset: Int, delta: Int, deltaHeight: CGFloat) {
        assert(
            offset >= 0 && offset <= self.length,
            "Invalid index, expected between 0 and \(self.length). Got \(offset)"
        )
        assert(delta != 0 || deltaHeight != 0, "Delta must be non-0")
        let position: NodePosition?
        if offset == self.length { // Updates at the end of the document are valid
            position = lastNode
        } else {
            position = search(for: offset)
        }
        guard let position else {
            assertionFailure("No line found at index \(offset)")
            return
        }
        if delta < 0 {
            assert(
                offset - position.textPos > delta,
                "Delta too large. Deleting \(-delta) from line at position \(offset) extends beyond the line's range."
            )
        }
        length += delta
        height += deltaHeight
        let node = nodesPtr + Int(position.handle)
        node.pointee.length += delta
        node.pointee.height += deltaHeight
        metaFixup(startingAt: position.handle, delta: delta, deltaHeight: deltaHeight)
    }

    /// Deletes the line containing the given index.
    public func delete(lineAt index: Int) {
        assert(index >= 0 && index <= self.length, "Invalid index, expected between 0 and \(self.length). Got \(index)")
        guard count > 1 else {
            removeAll()
            return
        }
        guard let position = search(for: index) else {
            assertionFailure("Failed to find node for index: \(index)")
            return
        }
        count -= 1
        length -= position.length
        height -= position.height
        deleteNode(position.handle)
    }

    public func removeAll() {
        if nodesCount > 0 {
            nodesPtr.deinitialize(count: nodesCount)
        }
        nodesCount = 0
        freeList.removeAll(keepingCapacity: true)
        rootHandle = Int32.min
        count = 0
        length = 0
        height = 0
    }

    /// Efficiently builds the tree from the given array of lines.
    /// - Note: Calls ``TextLineStorage/removeAll()`` before building.
    public func build(from lines: borrowing [BuildItem], estimatedLineHeight: CGFloat) {
        removeAll()
        // Reserve capacity up-front — one allocation for the full arena.
        ensureNodeCapacity(lines.count)
        let (handle, _, _, _) = buildSubtree(
            lines: lines,
            estimatedLineHeight: estimatedLineHeight,
            left: 0,
            right: lines.count,
            parent: Int32.min
        )
        rootHandle = handle
        count = lines.count
    }

    // swiftlint:disable large_tuple
    /// Recursively builds a subtree given an array of sorted lines, and a left and right indexes.
    /// - Returns: (rootHandle, offsetSum, heightSum, count) for the built subtree.
    private func buildSubtree(
        lines: borrowing [BuildItem],
        estimatedLineHeight: CGFloat,
        left: Int,
        right: Int,
        parent: NodeHandle
    ) -> (NodeHandle, Int, CGFloat, Int) {
        guard left < right else { return (Int32.min, 0, 0, 0) }
        let mid = left + (right - left) / 2

        let handle = allocNode(
            length: lines[mid].length,
            data: lines[mid].data,
            height: lines[mid].height ?? estimatedLineHeight,
            color: .black
        )
        self[handle].parent = parent

        let (leftHandle, leftOffset, leftHeight, leftCount) = buildSubtree(
            lines: lines,
            estimatedLineHeight: estimatedLineHeight,
            left: left,
            right: mid,
            parent: handle
        )
        let (rightHandle, rightOffset, rightHeight, rightCount) = buildSubtree(
            lines: lines,
            estimatedLineHeight: estimatedLineHeight,
            left: mid + 1,
            right: right,
            parent: handle
        )

        // `allocNode` may have grown the buffer during the recursive calls — re-read.
        let node = nodesPtr + Int(handle)
        node.pointee.left = leftHandle
        node.pointee.right = rightHandle

        // Leaves are red; internal nodes black. Same coloring as the original.
        if leftHandle == Int32.min && rightHandle == Int32.min {
            node.pointee.color = .red
        }

        length += node.pointee.length
        height += node.pointee.height
        node.pointee.leftSubtreeOffset = leftOffset
        node.pointee.leftSubtreeHeight = leftHeight
        node.pointee.leftSubtreeCount = leftCount

        return (
            handle,
            node.pointee.length + leftOffset + rightOffset,
            node.pointee.height + leftHeight + rightHeight,
            1 + leftCount + rightCount
        )
    }
}

// MARK: - Search

extension TextLineStorage {
    /// Searches for the given offset.
    @inlinable
    func search(for offset: Int) -> NodePosition? {
        guard rootHandle != Int32.min else { return nil }
        let ptr = nodesPtr
        let rootNode = ptr + Int(rootHandle)
        var currentHandle = rootHandle
        var currentOffset = rootNode.pointee.leftSubtreeOffset
        var currentYPosition = rootNode.pointee.leftSubtreeHeight
        var currentIndex = rootNode.pointee.leftSubtreeCount
        while currentHandle != Int32.min {
            let node = ptr + Int(currentHandle)
            let nodeLength = node.pointee.length
            if offset == currentOffset || (offset >= currentOffset && offset < currentOffset + nodeLength) {
                return NodePosition(
                    handle: currentHandle,
                    data: node.pointee.data,
                    length: nodeLength,
                    height: node.pointee.height,
                    yPos: currentYPosition,
                    textPos: currentOffset,
                    index: currentIndex
                )
            } else if currentOffset > offset {
                let left = node.pointee.left
                if left == Int32.min { return nil }
                let leftNode = ptr + Int(left)
                currentOffset += leftNode.pointee.leftSubtreeOffset - node.pointee.leftSubtreeOffset
                currentYPosition += leftNode.pointee.leftSubtreeHeight - node.pointee.leftSubtreeHeight
                currentIndex += leftNode.pointee.leftSubtreeCount - node.pointee.leftSubtreeCount
                currentHandle = left
            } else {
                let right = node.pointee.right
                if right == Int32.min { return nil }
                let rightNode = ptr + Int(right)
                currentOffset += nodeLength + rightNode.pointee.leftSubtreeOffset
                currentYPosition += node.pointee.height + rightNode.pointee.leftSubtreeHeight
                currentIndex += 1 + rightNode.pointee.leftSubtreeCount
                currentHandle = right
            }
        }
        return nil
    }

    /// Searches for the given index.
    @inlinable
    func search(forIndex index: Int) -> NodePosition? {
        guard rootHandle != Int32.min else { return nil }
        let ptr = nodesPtr
        let rootNode = ptr + Int(rootHandle)
        var currentHandle = rootHandle
        var currentOffset = rootNode.pointee.leftSubtreeOffset
        var currentYPosition = rootNode.pointee.leftSubtreeHeight
        var currentIndex = rootNode.pointee.leftSubtreeCount
        while currentHandle != Int32.min {
            let node = ptr + Int(currentHandle)
            if index == currentIndex {
                return NodePosition(
                    handle: currentHandle,
                    data: node.pointee.data,
                    length: node.pointee.length,
                    height: node.pointee.height,
                    yPos: currentYPosition,
                    textPos: currentOffset,
                    index: currentIndex
                )
            } else if currentIndex > index {
                let left = node.pointee.left
                if left == Int32.min { return nil }
                let leftNode = ptr + Int(left)
                currentOffset += leftNode.pointee.leftSubtreeOffset - node.pointee.leftSubtreeOffset
                currentYPosition += leftNode.pointee.leftSubtreeHeight - node.pointee.leftSubtreeHeight
                currentIndex += leftNode.pointee.leftSubtreeCount - node.pointee.leftSubtreeCount
                currentHandle = left
            } else {
                let right = node.pointee.right
                if right == Int32.min { return nil }
                let rightNode = ptr + Int(right)
                currentOffset += node.pointee.length + rightNode.pointee.leftSubtreeOffset
                currentYPosition += node.pointee.height + rightNode.pointee.leftSubtreeHeight
                currentIndex += 1 + rightNode.pointee.leftSubtreeCount
                currentHandle = right
            }
        }
        return nil
    }

    /// Searches for the node containing the given y position.
    @inlinable
    func search(forYPosition posY: CGFloat) -> NodePosition? {
        guard rootHandle != Int32.min else { return nil }
        let ptr = nodesPtr
        let rootNode = ptr + Int(rootHandle)
        var currentHandle = rootHandle
        var currentOffset = rootNode.pointee.leftSubtreeOffset
        var currentYPosition = rootNode.pointee.leftSubtreeHeight
        var currentIndex = rootNode.pointee.leftSubtreeCount
        while currentHandle != Int32.min {
            let node = ptr + Int(currentHandle)
            let nodeHeight = node.pointee.height
            if posY >= currentYPosition && posY < currentYPosition + nodeHeight {
                return NodePosition(
                    handle: currentHandle,
                    data: node.pointee.data,
                    length: node.pointee.length,
                    height: nodeHeight,
                    yPos: currentYPosition,
                    textPos: currentOffset,
                    index: currentIndex
                )
            } else if currentYPosition > posY {
                let left = node.pointee.left
                if left == Int32.min { return nil }
                let leftNode = ptr + Int(left)
                currentOffset += leftNode.pointee.leftSubtreeOffset - node.pointee.leftSubtreeOffset
                currentYPosition += leftNode.pointee.leftSubtreeHeight - node.pointee.leftSubtreeHeight
                currentIndex += leftNode.pointee.leftSubtreeCount - node.pointee.leftSubtreeCount
                currentHandle = left
            } else {
                let right = node.pointee.right
                if right == Int32.min { return nil }
                let rightNode = ptr + Int(right)
                currentOffset += node.pointee.length + rightNode.pointee.leftSubtreeOffset
                currentYPosition += nodeHeight + rightNode.pointee.leftSubtreeHeight
                currentIndex += 1 + rightNode.pointee.leftSubtreeCount
                currentHandle = right
            }
        }
        return nil
    }
}

// MARK: - Delete

private extension TextLineStorage {
    /// Basic RB-Tree node removal with specialization for node metadata.
    func deleteNode(_ nodeZ: NodeHandle) {
        let ptr = nodesPtr
        let zNode = ptr + Int(nodeZ)

        metaFixup(
            startingAt: nodeZ,
            delta: -zNode.pointee.length,
            deltaHeight: -zNode.pointee.height,
            nodeAction: .deleted
        )

        var nodeY = nodeZ
        var nodeX: NodeHandle = Int32.min
        var originalColor = zNode.pointee.color

        let zLeft = zNode.pointee.left
        let zRight = zNode.pointee.right

        if zLeft == Int32.min || zRight == Int32.min {
            nodeX = zRight != Int32.min ? zRight : zLeft
            transplant(nodeZ, with: nodeX)
        } else {
            nodeY = minimum(zRight)
            let yNode = ptr + Int(nodeY)

            // Remove nodeY from its original position.
            metaFixup(
                startingAt: nodeY,
                delta: -yNode.pointee.length,
                deltaHeight: -yNode.pointee.height,
                nodeAction: .deleted
            )

            originalColor = yNode.pointee.color
            nodeX = yNode.pointee.right

            if yNode.pointee.parent == nodeZ {
                if nodeX != Int32.min {
                    (ptr + Int(nodeX)).pointee.parent = nodeY
                }
            } else {
                transplant(nodeY, with: yNode.pointee.right)

                let yRight = yNode.pointee.right
                if yRight != Int32.min {
                    let yRightNode = ptr + Int(yRight)
                    yRightNode.pointee.leftSubtreeCount += yNode.pointee.leftSubtreeCount
                    yRightNode.pointee.leftSubtreeHeight += yNode.pointee.leftSubtreeHeight
                    yRightNode.pointee.leftSubtreeOffset += yNode.pointee.leftSubtreeOffset
                }

                let newRight = zNode.pointee.right
                yNode.pointee.right = newRight
                if newRight != Int32.min {
                    (ptr + Int(newRight)).pointee.parent = nodeY
                }
            }

            transplant(nodeZ, with: nodeY)
            let newLeft = zNode.pointee.left
            yNode.pointee.left = newLeft
            if newLeft != Int32.min {
                (ptr + Int(newLeft)).pointee.parent = nodeY
            }
            yNode.pointee.color = zNode.pointee.color
            yNode.pointee.leftSubtreeCount = zNode.pointee.leftSubtreeCount
            yNode.pointee.leftSubtreeHeight = zNode.pointee.leftSubtreeHeight
            yNode.pointee.leftSubtreeOffset = zNode.pointee.leftSubtreeOffset

            // nodeY re-inserted — bump metadata for its new position.
            metaFixup(
                startingAt: nodeY,
                delta: yNode.pointee.length,
                deltaHeight: yNode.pointee.height,
                nodeAction: .inserted
            )
        }

        if originalColor == .black && nodeX != Int32.min {
            deleteFixup(handle: nodeX)
        }

        // Return the removed slot to the free list.
        freeNode(nodeZ)
    }
}

// MARK: - Fixup

private extension TextLineStorage {
    func insertFixup(handle: NodeHandle) {
        let ptr = nodesPtr
        var nodeX = handle
        while nodeX != rootHandle {
            let parent = (ptr + Int(nodeX)).pointee.parent
            if parent == Int32.min || (ptr + Int(parent)).pointee.color != .red { break }

            let parentNode = ptr + Int(parent)
            let grandparent = parentNode.pointee.parent
            if grandparent == Int32.min { break }

            let gpNode = ptr + Int(grandparent)
            let parentIsLeft = gpNode.pointee.left == parent
            let uncle = parentIsLeft ? gpNode.pointee.right : gpNode.pointee.left

            if uncle != Int32.min && (ptr + Int(uncle)).pointee.color == .red {
                parentNode.pointee.color = .black
                (ptr + Int(uncle)).pointee.color = .black
                gpNode.pointee.color = .red
                nodeX = grandparent
                continue
            }

            if parentIsLeft {
                if parentNode.pointee.right == nodeX {
                    nodeX = parent
                    leftRotate(handle: nodeX)
                }
                let pAfter = (ptr + Int(nodeX)).pointee.parent
                (ptr + Int(pAfter)).pointee.color = .black
                let gpAfter = (ptr + Int(pAfter)).pointee.parent
                if gpAfter != Int32.min {
                    (ptr + Int(gpAfter)).pointee.color = .red
                    rightRotate(handle: gpAfter)
                }
            } else {
                if parentNode.pointee.left == nodeX {
                    nodeX = parent
                    rightRotate(handle: nodeX)
                }
                let pAfter = (ptr + Int(nodeX)).pointee.parent
                (ptr + Int(pAfter)).pointee.color = .black
                let gpAfter = (ptr + Int(pAfter)).pointee.parent
                if gpAfter != Int32.min {
                    (ptr + Int(gpAfter)).pointee.color = .red
                    leftRotate(handle: gpAfter)
                }
            }
        }

        if rootHandle != Int32.min {
            (ptr + Int(rootHandle)).pointee.color = .black
        }
    }

    // swiftlint:disable cyclomatic_complexity
    func deleteFixup(handle: NodeHandle) {
        let ptr = nodesPtr
        var nodeX = handle
        while nodeX != rootHandle && (ptr + Int(nodeX)).pointee.color == .black {
            var siblingHandle = sibling(nodeX)
            if siblingHandle != Int32.min && (ptr + Int(siblingHandle)).pointee.color == .red {
                (ptr + Int(siblingHandle)).pointee.color = .black
                let parent = (ptr + Int(nodeX)).pointee.parent
                if parent != Int32.min {
                    (ptr + Int(parent)).pointee.color = .red
                    if isLeftChild(nodeX) {
                        leftRotate(handle: nodeX)
                    } else {
                        rightRotate(handle: nodeX)
                    }
                }
                siblingHandle = sibling(nodeX)
            }

            let sibLeft = siblingHandle != Int32.min ? (ptr + Int(siblingHandle)).pointee.left : Int32.min
            let sibRight = siblingHandle != Int32.min ? (ptr + Int(siblingHandle)).pointee.right : Int32.min
            let sibLeftBlack = sibLeft == Int32.min || (ptr + Int(sibLeft)).pointee.color == .black
            let sibRightBlack = sibRight == Int32.min || (ptr + Int(sibRight)).pointee.color == .black

            if sibLeftBlack && sibRightBlack {
                if siblingHandle != Int32.min {
                    (ptr + Int(siblingHandle)).pointee.color = .red
                }
                let parent = (ptr + Int(nodeX)).pointee.parent
                if parent == Int32.min { break }
                nodeX = parent
            } else {
                if isLeftChild(nodeX) {
                    if sibRightBlack {
                        if sibLeft != Int32.min {
                            (ptr + Int(sibLeft)).pointee.color = .black
                        }
                        if siblingHandle != Int32.min {
                            (ptr + Int(siblingHandle)).pointee.color = .red
                            rightRotate(handle: siblingHandle)
                        }
                        let parent = (ptr + Int(nodeX)).pointee.parent
                        siblingHandle = parent != Int32.min ? (ptr + Int(parent)).pointee.right : Int32.min
                    }
                    let parent = (ptr + Int(nodeX)).pointee.parent
                    let parentColor: Color = parent != Int32.min ? (ptr + Int(parent)).pointee.color : .black
                    if siblingHandle != Int32.min {
                        let sibNode = ptr + Int(siblingHandle)
                        sibNode.pointee.color = parentColor
                        if sibNode.pointee.right != Int32.min {
                            (ptr + Int(sibNode.pointee.right)).pointee.color = .black
                        }
                    }
                    if parent != Int32.min {
                        (ptr + Int(parent)).pointee.color = .black
                    }
                    leftRotate(handle: nodeX)
                    nodeX = rootHandle
                } else {
                    if sibLeftBlack {
                        if sibRight != Int32.min {
                            (ptr + Int(sibRight)).pointee.color = .black
                        }
                        if siblingHandle != Int32.min {
                            (ptr + Int(siblingHandle)).pointee.color = .red
                            leftRotate(handle: siblingHandle)
                        }
                        let parent = (ptr + Int(nodeX)).pointee.parent
                        siblingHandle = parent != Int32.min ? (ptr + Int(parent)).pointee.left : Int32.min
                    }
                    let parent = (ptr + Int(nodeX)).pointee.parent
                    let parentColor: Color = parent != Int32.min ? (ptr + Int(parent)).pointee.color : .black
                    if siblingHandle != Int32.min {
                        let sibNode = ptr + Int(siblingHandle)
                        sibNode.pointee.color = parentColor
                        if sibNode.pointee.left != Int32.min {
                            (ptr + Int(sibNode.pointee.left)).pointee.color = .black
                        }
                    }
                    if parent != Int32.min {
                        (ptr + Int(parent)).pointee.color = .black
                    }
                    rightRotate(handle: nodeX)
                    nodeX = rootHandle
                }
            }
        }
        if nodeX != Int32.min {
            (ptr + Int(nodeX)).pointee.color = .black
        }
    }

    /// Walk up the tree, updating any `leftSubtree` metadata. Hoisted-pointer version —
    /// this is called on every insert/delete/update, and was previously (with the class
    /// Node implementation) the hottest function in the file.
    private func metaFixup(
        startingAt handle: NodeHandle,
        delta: Int,
        deltaHeight: CGFloat,
        nodeAction: MetaFixupAction = .none
    ) {
        let ptr = nodesPtr
        var child = handle
        var parent = (ptr + Int(child)).pointee.parent
        while parent != Int32.min {
            let parentNode = ptr + Int(parent)
            if parentNode.pointee.left == child {
                parentNode.pointee.leftSubtreeOffset += delta
                parentNode.pointee.leftSubtreeHeight += deltaHeight
                switch nodeAction {
                case .inserted:
                    parentNode.pointee.leftSubtreeCount += 1
                case .deleted:
                    parentNode.pointee.leftSubtreeCount -= 1
                case .none:
                    break
                }
            }
            child = parent
            parent = parentNode.pointee.parent
        }
    }
}

// MARK: - Rotations

private extension TextLineStorage {
    func rightRotate(handle: NodeHandle) {
        rotate(handle: handle, left: false)
    }

    func leftRotate(handle: NodeHandle) {
        rotate(handle: handle, left: true)
    }

    func rotate(handle: NodeHandle, left: Bool) {
        let ptr = nodesPtr
        let hNode = ptr + Int(handle)
        var nodeY: NodeHandle

        if left {
            nodeY = hNode.pointee.right
            guard nodeY != Int32.min else { return }
            let yNode = ptr + Int(nodeY)
            yNode.pointee.leftSubtreeOffset += hNode.pointee.leftSubtreeOffset + hNode.pointee.length
            yNode.pointee.leftSubtreeHeight += hNode.pointee.leftSubtreeHeight + hNode.pointee.height
            yNode.pointee.leftSubtreeCount += hNode.pointee.leftSubtreeCount + 1

            let yLeft = yNode.pointee.left
            hNode.pointee.right = yLeft
            if yLeft != Int32.min {
                (ptr + Int(yLeft)).pointee.parent = handle
            }
        } else {
            nodeY = hNode.pointee.left
            guard nodeY != Int32.min else { return }

            let yRight = (ptr + Int(nodeY)).pointee.right
            hNode.pointee.left = yRight
            if yRight != Int32.min {
                (ptr + Int(yRight)).pointee.parent = handle
            }
        }

        let yNode = ptr + Int(nodeY)
        let originalParent = hNode.pointee.parent
        yNode.pointee.parent = originalParent
        if originalParent == Int32.min {
            rootHandle = nodeY
        } else {
            let opNode = ptr + Int(originalParent)
            if opNode.pointee.left == handle {
                opNode.pointee.left = nodeY
            } else if opNode.pointee.right == handle {
                opNode.pointee.right = nodeY
            }
        }

        if left {
            yNode.pointee.left = handle
        } else {
            yNode.pointee.right = handle
            // After a right rotation, `handle`'s new left subtree is what used to be
            // nodeY's right subtree — recompute left-subtree metadata from that root.
            let meta = subtreeMeta(rootedAt: hNode.pointee.left)
            hNode.pointee.leftSubtreeOffset = meta.offset
            hNode.pointee.leftSubtreeHeight = meta.height
            hNode.pointee.leftSubtreeCount = meta.count
        }
        hNode.pointee.parent = nodeY
    }

    /// Total (length, height, count) of the subtree rooted at `handle`, inclusive.
    /// Iterative — walks the right spine, accumulating each node's left-subtree meta
    /// plus the node itself. `O(log n)` on a balanced tree.
    func subtreeMeta(rootedAt handle: NodeHandle) -> NodeSubtreeMetadata {
        let ptr = nodesPtr
        var current = handle
        var offset = 0
        var heightSum: CGFloat = 0
        var count = 0
        while current != Int32.min {
            let node = ptr + Int(current)
            offset += node.pointee.leftSubtreeOffset + node.pointee.length
            heightSum += node.pointee.leftSubtreeHeight + node.pointee.height
            count += node.pointee.leftSubtreeCount + 1
            current = node.pointee.right
        }
        return NodeSubtreeMetadata(height: heightSum, offset: offset, count: count)
    }
}

// swiftlint:enable file_length
