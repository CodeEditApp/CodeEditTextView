import Testing
import AppKit
@testable import CodeEditTextView

extension TextLineStorage {
    /// Validate that the internal tree is intact and correct.
    ///
    /// Ensures that:
    /// - All lines can be queried by their index starting from `0`.
    /// - All lines can be found by iterating `y` positions.
    func validateInternalState() {
        func validateLines(_ lines: [TextLineStorage<Data>.TextLinePosition]) {
            var _lastLine: TextLineStorage<Data>.TextLinePosition?
            for line in lines {
                guard let lastLine = _lastLine else {
                    #expect(line.index == 0)
                    _lastLine = line
                    return
                }

                #expect(line.index == lastLine.index + 1)
                #expect(line.yPos >= lastLine.yPos + lastLine.height)
                #expect(line.range.location == lastLine.range.max + 1)
                _lastLine = line
            }
        }

        let linesUsingIndex = (0..<count).compactMap({ getLine(atIndex: $0) })
        validateLines(linesUsingIndex)

        let linesUsingYValue = Array(linesStartingAt(0, until: height))
        validateLines(linesUsingYValue)
    }
}

@Suite
@MainActor
struct TextLayoutManagerTests {
    let textView: TextView
    let textStorage: NSTextStorage
    let layoutManager: TextLayoutManager

    init() throws {
        textView = TextView(string: "A\nB\nC\nD")
        textStorage = textView.textStorage
        layoutManager = try #require(textView.layoutManager)
    }

    @Test(
        arguments: [
            ("\nE", NSRange(location: 6, length: 0), 5),
            ("0\n", NSRange(location: 0, length: 0), 5), // at beginning
            ("A\nBC\nD", NSRange(location: 3, length: 0), 6), // in middle
            ("A\r\nB\nC\rD", NSRange(location: 0, length: 0), 7) // Insert mixed line breaks
        ]
    )
    func insertText(_ testItem: (String, NSRange, Int)) throws { // swiftlint:disable:this large_tuple
        let (insertText, insertRange, lineCount) = testItem

        textStorage.replaceCharacters(in: insertRange, with: insertText)

        #expect(layoutManager.lineCount == lineCount)
        #expect(layoutManager.lineStorage.length == textStorage.length)
        layoutManager.lineStorage.validateInternalState()
    }

    @Test(
        arguments: [
            (NSRange(location: 5, length: 2), 3), // At end
            (NSRange(location: 0, length: 2), 3), // At beginning
            (NSRange(location: 2, length: 3), 3) // In middle
        ]
    )
    func deleteText(_ testItem: (NSRange, Int)) throws {
        let (deleteRange, lineCount) = testItem

        textStorage.deleteCharacters(in: deleteRange)

        #expect(layoutManager.lineCount == lineCount)
        #expect(layoutManager.lineStorage.length == textStorage.length)
        layoutManager.lineStorage.validateInternalState()
    }

    @Test(
        arguments: [
            ("\nD\nE\nF", NSRange(location: 5, length: 2), 6), // At end
            ("A\nY\nZ", NSRange(location: 0, length: 1), 6), // At beginning
            ("1\n2\n", NSRange(location: 2, length: 4), 4), // In middle
            ("A\nB\nC\nD\nE\nF\nG", NSRange(location: 0, length: 7), 7), // Entire string
            ("A\r\nB\nC\r", NSRange(location: 0, length: 6), 4) // Mixed line breaks
        ]
    )
    func replaceText(_ testItem: (String, NSRange, Int)) throws { // swiftlint:disable:this large_tuple
        let (replaceText, replaceRange, lineCount) = testItem

        textStorage.replaceCharacters(in: replaceRange, with: replaceText)

        #expect(layoutManager.lineCount == lineCount)
        #expect(layoutManager.lineStorage.length == textStorage.length)
        layoutManager.lineStorage.validateInternalState()
    }
}
