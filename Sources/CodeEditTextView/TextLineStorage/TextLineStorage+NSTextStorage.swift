//
//  TextLineStorage+NSTextStorage.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 8/21/23.
//

import AppKit

extension TextLineStorage where Data == TextLine {
    /// Builds the line storage object from the given `NSTextStorage`.
    ///
    /// Lines are split by ``UTF16LineScanner``, which reproduces `NSString.getLineStart` exactly (the edit
    /// path splits inserted text with the same Foundation call, so both agree on every terminator).
    /// - Parameters:
    ///   - textStorage: The text storage object to use.
    ///   - estimatedLineHeight: The estimated height of each individual line.
    func buildFromTextStorage(_ textStorage: NSTextStorage, estimatedLineHeight: CGFloat) {
        // `NSTextStorage.string` bridges through a copy-on-write snapshot of the backing `NSBigMutableString`;
        // it is O(1), and the cast back hands over that same immutable object.
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
}
