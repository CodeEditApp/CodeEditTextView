import Testing
import Foundation
@testable import CodeEditTextView

/// Deterministic RNG so failures reproduce across runs.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58476D1CE4E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D049BB133111EB
        return mixed ^ (mixed >> 31)
    }
}

@Suite
struct LineStorageRegressionTests {
    private struct SubtreeAggregate {
        let length: Int
        let count: Int
        let height: CGFloat
    }

    /// Verifies the order-statistic metadata (`leftSubtree*` fields, totals, iteration
    /// order) is consistent with the actual tree contents.
    private func assertTreeMetadataCorrect<T: Identifiable>(
        _ tree: TextLineStorage<T>,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        func checkChildren(_ node: TextLineStorage<T>.NodeRef?) -> SubtreeAggregate {
            guard let node else { return SubtreeAggregate(length: 0, count: 0, height: 0.0) }
            let leftAggregate = checkChildren(node.left)
            let rightAggregate = checkChildren(node.right)

            #expect(
                leftAggregate.length == node.leftSubtreeOffset,
                "Left subtree length incorrect",
                sourceLocation: sourceLocation
            )
            #expect(
                leftAggregate.count == node.leftSubtreeCount,
                "Left subtree node count incorrect",
                sourceLocation: sourceLocation
            )
            #expect(
                abs(leftAggregate.height - node.leftSubtreeHeight) < 0.05,
                "Left subtree height incorrect",
                sourceLocation: sourceLocation
            )

            return SubtreeAggregate(
                length: node.length + leftAggregate.length + rightAggregate.length,
                count: 1 + leftAggregate.count + rightAggregate.count,
                height: node.height + leftAggregate.height + rightAggregate.height
            )
        }

        let rootAggregate = checkChildren(tree.root)
        #expect(rootAggregate.count == tree.count, "Node count incorrect", sourceLocation: sourceLocation)
        #expect(rootAggregate.length == tree.length, "Length incorrect", sourceLocation: sourceLocation)
        #expect(abs(rootAggregate.height - tree.height) < 0.05, "Height incorrect", sourceLocation: sourceLocation)

        var lastIndex = -1
        for line in tree {
            #expect(lastIndex == line.index - 1, "Incorrect index found", sourceLocation: sourceLocation)
            lastIndex = line.index
        }
    }

    /// Verifies the full set of red-black invariants plus the resulting depth bound:
    /// black root, no red node with a red child, uniform black-height on every
    /// root-to-nil path, and physical depth <= 2 * floor(log2(n + 1)).
    private func assertRedBlackInvariants<T: Identifiable>(
        _ tree: TextLineStorage<T>,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let root = tree.root else {
            #expect(tree.count == 0, "Empty tree with non-zero count", sourceLocation: sourceLocation)
            return
        }
        #expect(root.color == .black, "Root must be black", sourceLocation: sourceLocation)

        func check(_ node: TextLineStorage<T>.NodeRef?) -> (blackHeight: Int, depth: Int) {
            guard let node else { return (1, 0) }
            if node.color == .red {
                #expect(
                    node.left?.color != .red && node.right?.color != .red,
                    "Red node has a red child",
                    sourceLocation: sourceLocation
                )
            }
            let leftResult = check(node.left)
            let rightResult = check(node.right)
            #expect(
                leftResult.blackHeight == rightResult.blackHeight,
                "Black-height mismatch between subtrees",
                sourceLocation: sourceLocation
            )
            let blackHeight = max(leftResult.blackHeight, rightResult.blackHeight)
                + (node.color == .black ? 1 : 0)
            return (blackHeight, max(leftResult.depth, rightResult.depth) + 1)
        }

        let (_, depth) = check(root)
        let bound = 2 * Int(log2(Double(tree.count + 1)))
        #expect(
            depth <= bound,
            "Depth \(depth) exceeds red-black bound \(bound) for \(tree.count) nodes",
            sourceLocation: sourceLocation
        )
    }

    // MARK: - Delete rebalancing

    @Test
    func deletingBlackLeavesKeepsRedBlackInvariants() {
        let tree = TextLineStorage<TextLine>()
        for index in 0..<24 {
            tree.insert(line: TextLine(), atOffset: index, length: 1, height: 1.0)
        }
        assertRedBlackInvariants(tree)

        while tree.count > 1 {
            tree.delete(lineAt: 0)
            assertRedBlackInvariants(tree)
            assertTreeMetadataCorrect(tree)
        }
    }

    @Test
    func randomizedDeletionFromLargeTreeStaysBalanced() {
        // 4095 = 2^12 - 1: a perfect build shape, so this test isolates delete
        // rebalancing from build coloring.
        var rng = SplitMix64(seed: 0xC0DE)
        let tree = TextLineStorage<TextLine>()
        let items = (0..<4095).map { _ in
            TextLineStorage<TextLine>.BuildItem(data: TextLine(), length: 2, height: 1.0)
        }
        tree.build(from: items, estimatedLineHeight: 1.0)
        assertRedBlackInvariants(tree)

        var deletions = 0
        while tree.count > 64 {
            tree.delete(lineAt: Int.random(in: 0..<tree.length, using: &rng))
            deletions += 1
            if deletions % 250 == 0 {
                assertRedBlackInvariants(tree)
                assertTreeMetadataCorrect(tree)
            }
        }
        assertRedBlackInvariants(tree)
        assertTreeMetadataCorrect(tree)
    }

    @Test(arguments: [UInt64(1), 42, 0xDEAD_BEEF, 0xFEED_F00D])
    func randomizedMixedOperationsKeepRedBlackInvariants(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let tree = TextLineStorage<TextLine>()
        for _ in 0..<64 {
            tree.insert(
                line: TextLine(),
                atOffset: Int.random(in: 0...tree.length, using: &rng),
                length: Int.random(in: 1...20, using: &rng),
                height: 1.0
            )
        }

        for operation in 1...600 {
            switch Int.random(in: 0..<10, using: &rng) {
            case 0..<4:
                tree.insert(
                    line: TextLine(),
                    atOffset: Int.random(in: 0...tree.length, using: &rng),
                    length: Int.random(in: 1...20, using: &rng),
                    height: 1.0
                )
            case 4..<8 where tree.count > 32:
                tree.delete(lineAt: Int.random(in: 0..<tree.length, using: &rng))
            default:
                let index = Int.random(in: 0..<tree.count, using: &rng)
                guard let line = tree.getLine(atIndex: index) else {
                    Issue.record("Failed to find line at index \(index)")
                    return
                }
                // Keep lines at least 1 unit long so offset searches stay unambiguous.
                let maxShrink = line.range.length - 1
                let delta: Int
                if maxShrink > 0 && Bool.random(using: &rng) {
                    delta = -Int.random(in: 1...maxShrink, using: &rng)
                } else {
                    delta = Int.random(in: 1...10, using: &rng)
                }
                tree.update(atOffset: line.range.location, delta: delta, deltaHeight: 0.5)
            }

            if operation % 25 == 0 {
                assertRedBlackInvariants(tree)
                assertTreeMetadataCorrect(tree)
            }
        }
        assertRedBlackInvariants(tree)
        assertTreeMetadataCorrect(tree)
    }

    // MARK: - Build coloring

    @Test
    func buildProducesValidRedBlackTreeForAllSmallSizes() {
        for lineCount in 1...128 {
            let tree = TextLineStorage<TextLine>()
            let items = (0..<lineCount).map { _ in
                TextLineStorage<TextLine>.BuildItem(data: TextLine(), length: 3, height: 1.0)
            }
            tree.build(from: items, estimatedLineHeight: 1.0)
            assertRedBlackInvariants(tree)
            assertTreeMetadataCorrect(tree)
        }
    }

    @Test
    func buildThenEditKeepsRedBlackInvariants() {
        var rng = SplitMix64(seed: 0xBADD_CAFE)
        let tree = TextLineStorage<TextLine>()
        // Deliberately non-perfect size - a document load followed by editing.
        let items = (0..<3000).map { _ in
            TextLineStorage<TextLine>.BuildItem(data: TextLine(), length: 4, height: 1.0)
        }
        tree.build(from: items, estimatedLineHeight: 1.0)
        assertRedBlackInvariants(tree)

        for operation in 1...500 {
            if Bool.random(using: &rng) {
                tree.insert(
                    line: TextLine(),
                    atOffset: Int.random(in: 0...tree.length, using: &rng),
                    length: Int.random(in: 1...8, using: &rng),
                    height: 1.0
                )
            } else if tree.count > 1 {
                tree.delete(lineAt: Int.random(in: 0..<tree.length, using: &rng))
            }
            if operation % 100 == 0 {
                assertRedBlackInvariants(tree)
                assertTreeMetadataCorrect(tree)
            }
        }
        assertRedBlackInvariants(tree)
        assertTreeMetadataCorrect(tree)
    }

    // MARK: - Update shrink bounds

    @Test
    func updateAllowsShrinkToExactlyLineEnd() {
        let tree = TextLineStorage<TextLine>()
        tree.insert(line: TextLine(), atOffset: 0, length: 5, height: 1.0)
        tree.insert(line: TextLine(), atOffset: 5, length: 5, height: 1.0)

        // Second line spans 5..<10; from offset 7 exactly 3 units remain.
        tree.update(atOffset: 7, delta: -3, deltaHeight: 0.0)

        #expect(tree.length == 7)
        #expect(tree.getLine(atIndex: 1)?.range == NSRange(location: 5, length: 2))
        assertTreeMetadataCorrect(tree)
        assertRedBlackInvariants(tree)
    }

    @Test
    func updateAtDocumentEndAllowsShrinkWithinLastLine() {
        let tree = TextLineStorage<TextLine>()
        tree.insert(line: TextLine(), atOffset: 0, length: 6, height: 1.0)
        tree.insert(line: TextLine(), atOffset: 6, length: 4, height: 1.0)

        // End-of-document updates apply to the last line as a whole.
        tree.update(atOffset: tree.length, delta: -3, deltaHeight: 0.0)

        #expect(tree.length == 7)
        #expect(tree.last?.range == NSRange(location: 6, length: 1))
        assertTreeMetadataCorrect(tree)
        assertRedBlackInvariants(tree)
    }
}
