//
//  TextLineStorage+NSTextStorage.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 8/21/23.
//

import AppKit

extension TextLineStorage where Data == TextLine {
    /// Builds the line storage object from the given `NSTextStorage`. Each line's ``TextLine`` is created when the line
    /// is first read.
    ///
    /// Lines end at LF, CR and CR LF, found by ``UTF16LineScanner`` - the scanner the edit path splits inserted text
    /// with, so a document opens with the line structure any sequence of edits produces.
    /// - Parameters:
    ///   - textStorage: The text storage object to use.
    ///   - estimatedLineHeight: The estimated height of each individual line.
    func buildFromTextStorage(_ textStorage: NSTextStorage, estimatedLineHeight: CGFloat) {
        // The storage's live backing string, with no copy: the bridge round trip is elided. Fine for a synchronous
        // scan; anything reading it later or on another thread needs `(string as NSString).copy()`, an O(1)
        // copy-on-write snapshot.
        let string = textStorage.string as NSString
        let totalLength = string.length

        var lengths: [Int] = []
        // Average source line is ~35 UTF-16 units including its terminator; over-reserving slightly is
        // cheaper than a regrowth copy mid-scan.
        lengths.reserveCapacity(totalLength / 32 + 1)
        let terminalUnit = string.scanLineLengths(into: &lengths)

        // An empty document, or one whose final line ends in `\n` or `\r`, gets a trailing empty line.
        if totalLength == 0 || terminalUnit == 0x0A || terminalUnit == 0x0D {
            lengths.append(0)
        }

        build(lengths: lengths, estimatedLineHeight: estimatedLineHeight) { TextLine() }
    }

    /// Inserts a line whose ``TextLine`` is created when the line is first read.
    /// - Complexity: `O(log n)`
    func insertLine(atOffset index: Int, length: Int, height: CGFloat) {
        if dataFactory == nil {
            dataFactory = { TextLine() }
        }
        insertNode(data: nil, atOffset: index, length: length, height: height)
    }
}
