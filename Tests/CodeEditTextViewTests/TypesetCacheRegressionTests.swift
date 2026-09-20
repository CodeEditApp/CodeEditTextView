import Testing
import AppKit
import CoreText
@testable import CodeEditTextView

/// Pins the `TypesetCache` HIT reconstruction path end-to-end: a cache hit rebuilds `LineFragment`s through
/// `Typesetter.buildItems(from:lineHeightMultiplier:)`, which is different code than the miss path.
@Suite
@MainActor
struct TypesetCacheRegressionTests {
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)]

    init() {
        // Isolate from other suites sharing the process-global cache, and guarantee the first typeset in each
        // test below is a miss.
        TypesetCache.shared.removeAll()
    }

    private typealias FragmentPosition = TextLineStorage<LineFragment>.TextLinePosition

    private func typesetTwice(
        _ string: NSAttributedString,
        displayData: TextLine.DisplayData
    ) -> (miss: [FragmentPosition], hit: [FragmentPosition]) {
        let documentRange = NSRange(location: 0, length: string.length)
        let missTypesetter = Typesetter()
        missTypesetter.typeset(string, documentRange: documentRange, displayData: displayData, markedRanges: nil)
        // Identical content typeset again is a guaranteed cache hit.
        let hitTypesetter = Typesetter()
        hitTypesetter.typeset(
            NSAttributedString(attributedString: string),
            documentRange: documentRange,
            displayData: displayData,
            markedRanges: nil
        )
        return (Array(missTypesetter.lineFragments), Array(hitTypesetter.lineFragments))
    }

    @Test
    func cacheHitRebuildsIdenticalFragments() throws {
        let string = NSAttributedString(string: String(repeating: "A", count: 100), attributes: attributes)
        let displayData = TextLine.DisplayData(
            maxWidth: 150,
            lineHeightMultiplier: 1.0,
            estimatedLineHeight: 20.0,
            breakStrategy: .character
        )

        let (missFragments, hitFragments) = typesetTwice(string, displayData: displayData)
        try #require(missFragments.count > 1, "Expected the line to wrap into multiple fragments")
        #expect(hitFragments.count == missFragments.count)

        for (miss, hit) in zip(missFragments, hitFragments) {
            #expect(hit.range == miss.range)
            #expect(hit.data.width == miss.data.width)
            #expect(hit.data.height == miss.data.height)
            #expect(hit.data.descent == miss.data.descent)
            #expect(hit.data.scaledHeight == miss.data.scaledHeight)
            guard case .text(let missLine) = miss.data.contents.first?.data,
                  case .text(let hitLine) = hit.data.contents.first?.data else {
                Issue.record("Expected a single text content in each fragment")
                return
            }
            // A hit must reuse the cached CTLine instances - this proves the reconstruction path actually ran.
            #expect(missLine === hitLine)
        }
    }

    @Test
    func cacheHitReappliesLineHeightMultiplier() throws {
        let string = NSAttributedString(string: String(repeating: "A", count: 100), attributes: attributes)
        let displayData = TextLine.DisplayData(
            maxWidth: 150,
            lineHeightMultiplier: 2.0,
            estimatedLineHeight: 20.0,
            breakStrategy: .character
        )

        let (missFragments, hitFragments) = typesetTwice(string, displayData: displayData)
        try #require(missFragments.count > 1)
        #expect(hitFragments.count == missFragments.count)

        for (miss, hit) in zip(missFragments, hitFragments) {
            #expect(hit.range == miss.range)
            #expect(hit.data.scaledHeight == miss.data.scaledHeight)
            // The rebuild must re-apply the caller's multiplier, not a stored scaled height.
            #expect(abs(hit.data.scaledHeight - hit.data.height * 2.0) < 0.001)
            #expect(hit.height == hit.data.scaledHeight)
        }
    }
}
