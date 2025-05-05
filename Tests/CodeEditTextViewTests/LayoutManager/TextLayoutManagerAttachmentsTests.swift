//
//  TextLayoutManagerAttachmentsTests.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 5/5/25.
//

import Testing
import AppKit
@testable import CodeEditTextView

@Suite
@MainActor
struct TextLayoutManagerAttachmentsTests {
    let textView: TextView
    let textStorage: NSTextStorage
    let layoutManager: TextLayoutManager

    init() throws {
        textView = TextView(string: "A\nB\nC\nD")
        textView.frame = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        textStorage = textView.textStorage
        layoutManager = try #require(textView.layoutManager)
    }

    // MARK: - Determine Visible Line Tests

    @Test
    func determineVisibleLinesMovesForwards() {
        layoutManager.attachments.attachments(overlapping: <#T##NSRange#>)
    }

    @Test
    func determineVisibleLinesMovesBackwards() {

    }

    @Test
    func determineVisibleLinesMergesMultipleAttachments() {

    }

    // MARK: - Iterator Tests

    @Test
    func iterateWithAttachments() {

    }

    @Test
    func iterateWithMultilineAttachments() {

    }
}
