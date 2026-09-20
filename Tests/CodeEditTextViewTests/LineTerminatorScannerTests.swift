//
//  LineTerminatorScannerTests.swift
//  CodeEditTextViewTests
//

import XCTest
@testable import CodeEditTextView

/// Verifies ``UTF16LineScanner`` against Foundation's `getLineStart` for every code unit and every window
/// boundary, and the document build path against the per-line `getNextLine` algorithm it replaced.
final class LineTerminatorScannerTests: XCTestCase {
    private static let windowSizes = [1, 2, 3, 7, 15, 16, 17, 31, 32, 33, 100, UTF16LineScanner.defaultWindowUnits]

    // MARK: - References

    /// One `getLineStart` call per line: the algorithm `buildFromTextStorage` used before the scanner.
    private func reference(_ string: NSString) -> (lengths: [Int], endsWithTerminator: Bool) {
        var lengths: [Int] = []
        var index = 0
        while let range = string.getNextLine(startingAt: index) {
            lengths.append(range.max - index)
            index = NSMaxRange(range)
        }
        if string.length - index > 0 {
            lengths.append(string.length - index)
        }
        return (lengths, string.length > 0 && index == string.length)
    }

    /// Reference line lengths plus the trailing-empty-line rule of the original build path.
    private func referenceBuildLengths(_ string: NSString) -> [Int] {
        var lengths = reference(string).lengths
        if string.length == 0 || LineEnding(rawValue: string.substring(from: string.length - 1)) != nil {
            lengths.append(0)
        }
        return lengths
    }

    private func assertMatchesFoundation(
        _ text: String,
        windowUnits: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let string = text as NSString
        let expected = reference(string)
        var lengths: [Int] = []
        let terminal = string.scanLineLengths(into: &lengths, windowUnits: windowUnits)
        let context = "window \(windowUnits) for \(text.debugDescription)"
        XCTAssertEqual(lengths, expected.lengths, context, file: file, line: line)
        let expectedTerminal: UInt16? = expected.endsWithTerminator ? string.character(at: string.length - 1) : nil
        XCTAssertEqual(terminal, expectedTerminal, context, file: file, line: line)
    }

    // MARK: - Scanner vs Foundation

    func test_everyCodeUnitMatchesFoundation() {
        var terminators: [UInt16] = []
        for unit in 0..<0x1_0000 where !(0xD800...0xDFFF).contains(unit) {
            let units: [unichar] = [0x61, unichar(unit), 0x62]
            let string = NSString(characters: units, length: units.count)
            let expected = reference(string)
            var lengths: [Int] = []
            let terminal = string.scanLineLengths(into: &lengths)
            XCTAssertEqual(lengths, expected.lengths, String(format: "U+%04X", unit))
            XCTAssertNil(terminal)
            if lengths.count == 2 {
                terminators.append(unichar(unit))
            }
        }
        XCTAssertEqual(terminators, [0x0A, 0x0D, 0x85, 0x2028, 0x2029])
    }

    func test_terminatorSequencesMatchFoundationAtEveryWindowSize() {
        let cases = [
            "", "a", "\n", "\r", "\r\n", "\n\r", "\r\r", "\n\n\n", "\r\n\r\n",
            "a\r\nb", "a\n\rb", "a\r\r\nb", "abc\r", "abc\n", "abc\r\n",
            "a\u{85}\n", "a\u{85}", "\u{2028}\u{2029}", "a\u{2028}", "a\u{2029}b",
            "a\u{0B}b\u{0C}c", "a\t\tb\n\t\tc",
            "a\u{1F389}\nb", "\u{1F389}\r\n\u{1F389}", "e\u{0301}\r\n",
            String(repeating: "x", count: 100) + "\n" + String(repeating: "y", count: 15) + "\r\n",
            String(repeating: "\r\n", count: 40),
            String(repeating: "\n", count: 33),
            String(repeating: "abcdefghijklmno\n", count: 5) + "tail",
            String(repeating: "abcdefghijklmn\r\n", count: 5),
            String(repeating: "abcdefghijklmnop", count: 4) + "\r" + "\n" + "end",
        ]
        for text in cases {
            for window in Self.windowSizes {
                assertMatchesFoundation(text, windowUnits: window)
            }
        }
    }

    func test_randomDocumentsMatchFoundationAtEveryWindowSize() {
        let alphabet = ["a", "b", " ", "\t", "\n", "\r", "\r\n", "\u{85}", "\u{2028}", "\u{2029}", "\u{0B}",
                        "\u{0C}", "é", "日本", "🎉", "e\u{0301}"]
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        for _ in 0..<300 {
            let text = (0..<next(400)).map { _ in alphabet[next(alphabet.count)] }.joined()
            for window in [1, 5, 16, 17, 64, 4_096] {
                assertMatchesFoundation(text, windowUnits: window)
            }
        }
    }

    func test_forEachLineInSubrangesMatchesFoundation() {
        let alphabet = ["a", "b", "\n", "\r", "\r\n", "\u{85}", "\u{2028}", "\u{2029}", "日", "🎉"]
        var state: UInt64 = 0x1234_5678_9ABC_DEF1
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        for _ in 0..<200 {
            let string = (0..<(1 + next(120))).map { _ in alphabet[next(alphabet.count)] }.joined() as NSString
            let location = next(string.length)
            let range = NSRange(location: location, length: next(string.length - location + 1))
            let substring = string.substring(with: range) as NSString
            let expected = reference(substring)
            var expectedTerminators: [UInt16] = []
            var offset = 0
            for (index, length) in expected.lengths.enumerated() {
                offset += length
                let terminated = index < expected.lengths.count - 1 || expected.endsWithTerminator
                expectedTerminators.append(terminated ? substring.character(at: offset - 1) : 0)
            }
            for window in [1, 3, 16, 17, 64] {
                var lengths: [Int] = []
                var terminators: [UInt16] = []
                string.forEachLine(in: range, windowUnits: window) { length, terminator in
                    lengths.append(length)
                    terminators.append(terminator)
                }
                let context = "range \(range) window \(window) of \((string as String).debugDescription)"
                XCTAssertEqual(lengths, expected.lengths, context)
                XCTAssertEqual(terminators, expectedTerminators, context)
            }
        }
    }

    // MARK: - Document build vs reference

    private func assertBuildMatchesReference(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let storage = NSTextStorage(string: text)
        let expected = referenceBuildLengths(text as NSString)
        let tree = TextLineStorage<TextLine>()
        tree.buildFromTextStorage(storage, estimatedLineHeight: 10)

        XCTAssertEqual(tree.count, expected.count, text.debugDescription, file: file, line: line)
        XCTAssertEqual(tree.length, storage.length, text.debugDescription, file: file, line: line)
        XCTAssertEqual(tree.height, CGFloat(expected.count) * 10, text.debugDescription, file: file, line: line)

        var offset = 0
        var visited = 0
        for position in tree {
            let range = NSRange(location: offset, length: expected[visited])
            XCTAssertEqual(position.range, range, text.debugDescription, file: file, line: line)
            XCTAssertEqual(position.index, visited, file: file, line: line)
            XCTAssertEqual(position.yPos, CGFloat(visited) * 10, file: file, line: line)
            XCTAssertEqual(tree.getLine(atIndex: visited)?.range, range, file: file, line: line)
            XCTAssertEqual(tree.getLine(atOffset: offset)?.index, visited, file: file, line: line)
            if range.length > 0 {
                XCTAssertEqual(tree.getLine(atOffset: range.max - 1)?.index, visited, file: file, line: line)
            }
            offset += range.length
            visited += 1
        }
        XCTAssertEqual(visited, expected.count, file: file, line: line)
    }

    func test_buildFromTextStorageMatchesReference() {
        let cases = [
            "", "a", "\n", "\r", "\r\n", "a\n", "a\r", "a\r\n", "a\u{85}", "a\u{2028}", "a\u{2029}",
            "one\ntwo\nthree", "one\ntwo\nthree\n", "one\r\ntwo\r\n", "\n\n\n", "\r\r\r",
            "mixed\r\nendings\rhere\nand\u{2028}there\u{85}too\u{2029}done\n",
            "🎉\n日本語\r\ncafé\n", String(repeating: "line\n", count: 1_000),
            (0..<777).map { String(repeating: "x", count: $0 % 23) }.joined(separator: "\n"),
        ]
        for text in cases {
            assertBuildMatchesReference(text)
        }
    }

    func test_buildFromTextStorageLargeVariedDocument() {
        var text = ""
        for index in 0..<50_000 {
            text += String(repeating: "x", count: (index &* 37) % 120)
            text += index % 7 == 0 ? "\r\n" : "\n"
        }
        assertBuildMatchesReference(text)
    }

    func test_buildFromLengthsMatchesBuildFromItems() {
        let lengths = (0..<1_234).map { ($0 &* 13) % 50 }
        let fromLengths = TextLineStorage<TextLine>()
        fromLengths.build(lengths: lengths, estimatedLineHeight: 3) { TextLine() }
        let fromItems = TextLineStorage<TextLine>()
        fromItems.build(
            from: lengths.map { TextLineStorage<TextLine>.BuildItem(data: TextLine(), length: $0, height: nil) },
            estimatedLineHeight: 3
        )
        XCTAssertEqual(fromLengths.count, fromItems.count)
        XCTAssertEqual(fromLengths.length, fromItems.length)
        XCTAssertEqual(fromLengths.height, fromItems.height)
        for (lhs, rhs) in zip(fromLengths, fromItems) {
            XCTAssertEqual(lhs.range, rhs.range)
            XCTAssertEqual(lhs.index, rhs.index)
            XCTAssertEqual(lhs.yPos, rhs.yPos)
        }
    }

    // MARK: - Allocation behavior

    func test_emptyStorageAllocatesNoArenaUntilFirstNode() {
        let storage = TextLineStorage<TextLine>()
        XCTAssertEqual(storage.nodesCapacity, 0)
        XCTAssertNil(storage.first)
        XCTAssertNil(storage.last)
        storage.removeAll()
        XCTAssertEqual(storage.nodesCapacity, 0)
        storage.insert(line: TextLine(), atOffset: 0, length: 1, height: 1)
        XCTAssertGreaterThan(storage.nodesCapacity, 0)
        XCTAssertEqual(storage.count, 1)
    }

    func test_textLineTypesetterIsLazy() {
        let line = TextLine()
        let typesetter = line.typesetter
        XCTAssertTrue(typesetter === line.typesetter)
        XCTAssertTrue(line.lineFragments.isEmpty)
        line.setNeedsLayout()
        XCTAssertTrue(typesetter === line.typesetter, "invalidation keeps the typesetter and its arena")
        XCTAssertTrue(line.lineFragments.isEmpty)
    }

    func test_uniqueIdentifiersAreUnique() {
        var seen = Set<UUID>()
        for _ in 0..<200_000 {
            XCTAssertTrue(seen.insert(UniqueIdentifier.makeUUID()).inserted)
        }
        XCTAssertNotEqual(TextLine().id, TextLine().id)
    }
}
