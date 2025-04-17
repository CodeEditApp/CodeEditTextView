import Testing
import AppKit
@testable import CodeEditTextView

class MockRenderDelegate: TextLayoutManagerRenderDelegate {
    var prepareForDisplay: ((
        _ textLine: TextLine,
        _ displayData: TextLine.DisplayData,
        _ range: NSRange,
        _ stringRef: NSTextStorage,
        _ markedRanges: MarkedRanges?,
        _ breakStrategy: LineBreakStrategy
    ) -> Void)?

    func prepareForDisplay( // swiftlint:disable:this function_parameter_count
        textLine: TextLine,
        displayData: TextLine.DisplayData,
        range: NSRange,
        stringRef: NSTextStorage,
        markedRanges: MarkedRanges?,
        breakStrategy: LineBreakStrategy
    ) {
        prepareForDisplay?(
            textLine,
            displayData,
            range,
            stringRef,
            markedRanges,
            breakStrategy
        ) ?? textLine.prepareForDisplay(
            displayData: displayData,
            range: range,
            stringRef: stringRef,
            markedRanges: markedRanges,
            breakStrategy: breakStrategy
        )
    }
}

@Suite
@MainActor
struct OverridingLayoutManagerRenderingTests {
    let mockDelegate: MockRenderDelegate
    let textView: TextView
    let textStorage: NSTextStorage
    let layoutManager: TextLayoutManager

    init() throws {
        textView = TextView(string: "A\nB\nC\nD")
        textView.frame = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        textStorage = textView.textStorage
        layoutManager = try #require(textView.layoutManager)
        mockDelegate = MockRenderDelegate()
        layoutManager.renderDelegate = mockDelegate
    }

    @Test
    func overriddenLineHeight() {
        mockDelegate.prepareForDisplay = { textLine, displayData, range, stringRef, markedRanges, breakStrategy in
            textLine.prepareForDisplay(
                displayData: displayData,
                range: range,
                stringRef: stringRef,
                markedRanges: markedRanges,
                breakStrategy: breakStrategy
            )
            // Update all text fragments to be height = 2.0
            textLine.lineFragments.forEach { fragmentPosition in
                let idealHeight: CGFloat = 2.0
                textLine.lineFragments.update(
                    atOffset: fragmentPosition.index,
                    delta: 0,
                    deltaHeight: -(fragmentPosition.height - idealHeight)
                )
                fragmentPosition.data.height = 2.0
                fragmentPosition.data.scaledHeight = 2.0
            }
        }

        layoutManager.invalidateLayoutForRect(NSRect(x: 0, y: 0, width: 1000, height: 1000))
        layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 1000, height: 1000))

        // 4 lines, each 2px tall
        #expect(layoutManager.lineStorage.height == 8.0)

        // Edit some text

        textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "0\n1\r\n2\r")
        layoutManager.layoutLines(in: NSRect(x: 0, y: 0, width: 1000, height: 1000))

        #expect(layoutManager.lineCount == 7)
        #expect(layoutManager.lineStorage.height == 14.0)
        layoutManager.lineStorage.validateInternalState()
    }
}
