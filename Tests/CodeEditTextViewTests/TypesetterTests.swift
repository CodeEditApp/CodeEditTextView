import XCTest
@testable import CodeEditTextView

// swiftlint:disable all

class TypesetterTests: XCTestCase {
    let limitedLineWidthDisplayData = TextLine.DisplayData(maxWidth: 150, lineHeightMultiplier: 1.0, estimatedLineHeight: 20.0)
    let unlimitedLineWidthDisplayData = TextLine.DisplayData(maxWidth: .infinity, lineHeightMultiplier: 1.0, estimatedLineHeight: 20.0)

    func test_LineFeedBreak() {
        let typesetter = Typesetter()
        typesetter.typeset(
            NSAttributedString(string: "testline\n"),
            displayData: unlimitedLineWidthDisplayData,
            breakStrategy: .word,
            markedRanges: nil
        )

        XCTAssertEqual(typesetter.lineFragments.count, 1, "Typesetter typeset incorrect number of lines.")

        typesetter.typeset(
            NSAttributedString(string: "testline\n"),
            displayData: unlimitedLineWidthDisplayData,
            breakStrategy: .character,
            markedRanges: nil
        )

        XCTAssertEqual(typesetter.lineFragments.count, 1, "Typesetter typeset incorrect number of lines.")
    }

    func test_carriageReturnBreak() {
        let typesetter = Typesetter()
        typesetter.typeset(
            NSAttributedString(string: "testline\r"),
            displayData: unlimitedLineWidthDisplayData,
            breakStrategy: .word,
            markedRanges: nil
        )

        XCTAssertEqual(typesetter.lineFragments.count, 1, "Typesetter typeset incorrect number of lines.")

        typesetter.typeset(
            NSAttributedString(string: "testline\r"),
            displayData: unlimitedLineWidthDisplayData,
            breakStrategy: .character,
            markedRanges: nil
        )

        XCTAssertEqual(typesetter.lineFragments.count, 1, "Typesetter typeset incorrect number of lines.")
    }

    func test_carriageReturnLineFeedBreak() {
        let typesetter = Typesetter()
        typesetter.typeset(
            NSAttributedString(string: "testline\r\n"),
            displayData: unlimitedLineWidthDisplayData,
            breakStrategy: .word,
            markedRanges: nil
        )

        XCTAssertEqual(typesetter.lineFragments.count, 1, "Typesetter typeset incorrect number of lines.")

        typesetter.typeset(
            NSAttributedString(string: "testline\r\n"),
            displayData: unlimitedLineWidthDisplayData,
            breakStrategy: .character,
            markedRanges: nil
        )

        XCTAssertEqual(typesetter.lineFragments.count, 1, "Typesetter typeset incorrect number of lines.")
    }
}

// swiftlint:enable all
