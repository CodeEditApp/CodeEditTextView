import Testing
import AppKit
import CoreText
@testable import CodeEditTextView

private final class BoxAttachment: TextAttachment {
    var width: CGFloat = 20
    var isSelected: Bool = false

    func draw(in context: CGContext, rect: NSRect) { }
}

private final class CountingInvisiblesDelegate: InvisibleCharactersDelegate {
    var triggerCharacters: Set<UInt16> = [0x9] // \t
    var seenLocations: [Int] = []

    func invisibleStyleShouldClearCache() -> Bool { false }

    func invisibleStyle(for character: UInt16, at range: NSRange, lineRange: NSRange) -> InvisibleCharacterStyle? {
        seenLocations.append(range.location)
        return .emphasize(color: .red)
    }
}

@Suite
@MainActor
struct TypesetterRegressionTests {
    // NOTE: makes chars that are ~6.18pts wide
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)]

    init() {
        // Isolate every test from the process-global typeset cache so a test never consumes a cached result
        // produced by an earlier test (which would mask miss-path regressions).
        TypesetCache.shared.removeAll()
    }

    private func makeDisplayData(
        maxWidth: CGFloat,
        breakStrategy: LineBreakStrategy = .character
    ) -> TextLine.DisplayData {
        TextLine.DisplayData(
            maxWidth: maxWidth,
            lineHeightMultiplier: 1.0,
            estimatedLineHeight: 20.0,
            breakStrategy: breakStrategy
        )
    }

    // MARK: - Wrapped fragment CTLine ranges

    @Test
    func wrappedFragmentCTLinesMatchFragmentRanges() {
        let typesetter = Typesetter()
        typesetter.typeset(
            NSAttributedString(string: String(repeating: "A", count: 100), attributes: attributes),
            documentRange: NSRange(location: 0, length: 100),
            displayData: makeDisplayData(maxWidth: 150),
            markedRanges: nil
        )

        #expect(typesetter.lineFragments.count > 1, "Expected the line to wrap into multiple fragments")

        var coveredLength = 0
        for fragment in typesetter.lineFragments {
            guard let content = fragment.data.contents.first, case .text(let ctLine) = content.data else {
                Issue.record("Expected a single text content in each fragment")
                return
            }
            let ctRange = CTLineGetStringRange(ctLine)
            // Each fragment's CTLine must cover exactly the fragment's range - no more, no less.
            #expect(ctRange.location == fragment.range.location)
            #expect(ctRange.length == fragment.range.length)
            // A wrapped fragment cannot be wider than the wrap width.
            #expect(fragment.data.width <= 150.5)
            coveredLength += fragment.range.length
        }
        #expect(coveredLength == 100)
    }

    // MARK: - Degenerate wrap widths

    @Test
    func tinyWrapWidthMakesForwardProgress() {
        // Wrap width smaller than a single glyph: layout must terminate, consuming >= 1 UTF-16
        // unit per fragment.
        let typesetter = Typesetter()
        typesetter.typeset(
            NSAttributedString(string: "ABCDEF", attributes: attributes),
            documentRange: NSRange(location: 0, length: 6),
            displayData: makeDisplayData(maxWidth: 3),
            markedRanges: nil
        )

        #expect(typesetter.lineFragments.count == 6)
        var coveredLength = 0
        for fragment in typesetter.lineFragments {
            #expect(fragment.range.length == 1)
            coveredLength += fragment.range.length
        }
        #expect(coveredLength == 6)
    }

    @Test
    func tinyWrapWidthDoesNotSplitSurrogatePairs() {
        let typesetter = Typesetter()
        typesetter.typeset(
            NSAttributedString(string: "😀😀", attributes: attributes),
            documentRange: NSRange(location: 0, length: 4),
            displayData: makeDisplayData(maxWidth: 3),
            markedRanges: nil
        )

        #expect(typesetter.lineFragments.count == 2)
        for fragment in typesetter.lineFragments {
            #expect(fragment.range.length == 2, "A surrogate pair must never be split across fragments")
            guard let content = fragment.data.contents.first, case .text(let ctLine) = content.data else {
                Issue.record("Expected a single text content in each fragment")
                return
            }
            let ctRange = CTLineGetStringRange(ctLine)
            #expect(ctRange.location == fragment.range.location)
            #expect(ctRange.length == fragment.range.length)
        }
    }

    @Test(arguments: [CGFloat(0.0), CGFloat(-100.0), CGFloat.nan])
    func nonPositiveWrapWidthTypesetsUnwrapped(width: CGFloat) throws {
        // A zero/negative/NaN wrap width must produce a normal unwrapped typeset, not empty
        // fragments for non-empty content.
        let typesetter = Typesetter()
        typesetter.typeset(
            NSAttributedString(string: "Hello, world", attributes: attributes),
            documentRange: NSRange(location: 0, length: 12),
            displayData: makeDisplayData(maxWidth: width),
            markedRanges: nil
        )

        #expect(typesetter.lineFragments.count == 1)
        let fragment = try #require(typesetter.lineFragments.first)
        #expect(fragment.range.length == 12)
        #expect(fragment.data.width > 0)
    }

    // MARK: - Width transitions

    @Test
    func lineTypesetAtInfiniteWidthRelaysOutAtFiniteWidth() {
        let storage = NSTextStorage(string: String(repeating: "A", count: 200), attributes: attributes)
        let line = TextLine()
        line.prepareForDisplay(
            displayData: makeDisplayData(maxWidth: .infinity),
            range: NSRange(location: 0, length: 200),
            stringRef: storage,
            markedRanges: nil,
            attachments: []
        )

        // Attaching to a scroll view moves the wrap width from infinite to finite; the line must
        // re-typeset or long lines stay unwrapped and clipped.
        #expect(line.needsLayout(maxWidth: 500))
        #expect(!line.needsLayout(maxWidth: .infinity))
    }

    @Test
    func lineTypesetAtFiniteWidthTracksWidthChanges() {
        let storage = NSTextStorage(string: String(repeating: "A", count: 200), attributes: attributes)
        let line = TextLine()
        line.prepareForDisplay(
            displayData: makeDisplayData(maxWidth: 500),
            range: NSRange(location: 0, length: 200),
            stringRef: storage,
            markedRanges: nil,
            attachments: []
        )

        #expect(!line.needsLayout(maxWidth: 500))
        #expect(line.needsLayout(maxWidth: 300))
        #expect(line.needsLayout(maxWidth: .infinity))
    }

    // MARK: - Typeset cache

    @Test
    func midLineAttributeChangeProducesNewTypesetOutput() throws {
        let text = "    someCall(foo)"
        let displayData = makeDisplayData(maxWidth: .greatestFiniteMagnitude)

        let plainTypesetter = Typesetter()
        plainTypesetter.typeset(
            NSAttributedString(string: text, attributes: attributes),
            documentRange: NSRange(location: 0, length: text.utf16.count),
            displayData: displayData,
            markedRanges: nil
        )
        let plainWidth = try #require(plainTypesetter.lineFragments.first).data.width

        // Same characters, same index-0 attributes, but a larger font mid-line - as syntax
        // highlighting would apply. The typeset output must reflect the new attributes.
        let highlighted = NSMutableAttributedString(string: text, attributes: attributes)
        highlighted.addAttribute(
            .font,
            value: NSFont.monospacedSystemFont(ofSize: 20, weight: .regular),
            range: NSRange(location: 4, length: 8)
        )
        let highlightedTypesetter = Typesetter()
        highlightedTypesetter.typeset(
            highlighted,
            documentRange: NSRange(location: 0, length: text.utf16.count),
            displayData: displayData,
            markedRanges: nil
        )
        let highlightedWidth = try #require(highlightedTypesetter.lineFragments.first).data.width

        #expect(highlightedWidth > plainWidth + 10.0)
    }

    @Test
    func cacheKeyDistinguishesMidLineAttributeChanges() {
        let text = String(repeating: "x", count: 40)
        let plain = NSAttributedString(string: text, attributes: attributes)
        let recolored = NSMutableAttributedString(string: text, attributes: attributes)
        recolored.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 10, length: 5))

        let displayData = makeDisplayData(maxWidth: 500)
        let plainKey = TypesetCacheKey.make(string: plain, displayData: displayData)
        let recoloredKey = TypesetCacheKey.make(string: recolored, displayData: displayData)
        let equalPlainKey = TypesetCacheKey.make(
            string: NSAttributedString(attributedString: plain),
            displayData: displayData
        )

        #expect(plainKey != recoloredKey)
        #expect(plainKey == equalPlainKey)
    }

    @Test
    func cacheKeyDistinguishesLongLinesWithSampledHashCollisions() {
        // NSString.hash samples a bounded subset of characters on long strings. Two lines of equal
        // length differing only at an unsampled index must still produce distinct keys.
        var otherChars = Array(repeating: Character("A"), count: 200)
        otherChars[50] = "B"
        let lineA = NSAttributedString(string: String(repeating: "A", count: 200), attributes: attributes)
        let lineB = NSAttributedString(string: String(otherChars), attributes: attributes)

        let displayData = makeDisplayData(maxWidth: 500)
        let keyA = TypesetCacheKey.make(string: lineA, displayData: displayData)
        let keyB = TypesetCacheKey.make(string: lineB, displayData: displayData)

        #expect(keyA != keyB)

        let cache = TypesetCache(capacity: 4)
        cache.set(keyA, CachedTypesetResult(fragments: [], maxHeight: 10))
        #expect(cache.get(keyB) == nil, "A different line must never hit another line's cached typeset result")
    }

    // MARK: - Invisible character scanning

    @Test
    func invisibleCharacterScanStopsAtContentBoundary() throws {
        let text = "ABX\tCD"
        let storage = NSTextStorage(string: text, attributes: attributes)
        let attachment = AnyTextAttachment(range: NSRange(location: 2, length: 1), attachment: BoxAttachment())
        let typesetter = Typesetter()
        typesetter.typeset(
            NSAttributedString(string: text, attributes: attributes),
            documentRange: NSRange(location: 0, length: 6),
            displayData: makeDisplayData(maxWidth: .greatestFiniteMagnitude),
            markedRanges: nil,
            attachments: [attachment]
        )

        let fragment = try #require(typesetter.lineFragments.first).data
        #expect(fragment.contents.count == 3)
        fragment.documentRange = NSRange(location: 0, length: 6)

        let delegate = CountingInvisiblesDelegate()
        let renderer = LineFragmentRenderer(textStorage: storage, invisibleCharacterDelegate: delegate)
        let context = try #require(
            CGContext(
                data: nil,
                width: 200,
                height: 40,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        renderer.draw(lineFragment: fragment, in: context, yPos: 0.0)

        // The tab after the attachment belongs to the trailing text content only. It must be
        // queried exactly once - not re-scanned by the leading text content's pass.
        #expect(delegate.seenLocations == [3])
    }
}
