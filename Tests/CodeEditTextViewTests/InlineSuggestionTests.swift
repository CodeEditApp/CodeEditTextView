//
//  InlineSuggestionTests.swift
//  CodeEditTextView
//
//  Created by anxkhn on 6/29/26.
//

import Testing
import AppKit
@testable import CodeEditTextView

@Suite
@MainActor
struct InlineSuggestionTests {
    let textView: TextView
    let textStorage: NSTextStorage

    init() throws {
        textView = TextView(string: "Hello World")
        textView.frame = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        textStorage = textView.textStorage
        textView.layoutManager.layoutLines()
    }

    private func suggestionViews() -> [InlineSuggestionView] {
        textView.subviews.compactMap { $0 as? InlineSuggestionView }
    }

    @Test
    func setSuggestionAddsSingleOverlayWithoutMutatingStorage() throws {
        let lengthBefore = textStorage.length
        let documentRangeBefore = textView.documentRange

        textView.setInlineSuggestion("suggested", at: 5)

        #expect(suggestionViews().count == 1)
        #expect(textView.inlineSuggestionManager?.current == InlineSuggestion(offset: 5, text: "suggested"))

        // The ghost text must never mutate the underlying storage or document range.
        #expect(textStorage.length == lengthBefore)
        #expect(textView.documentRange == documentRangeBefore)
    }

    @Test
    func overlayIsAnchoredAtCaretRect() throws {
        let offset = 5
        textView.setInlineSuggestion("suggested", at: offset)

        let caretRect = try #require(textView.layoutManager.rectForOffset(offset))
        let view = try #require(suggestionViews().first)

        #expect(view.frame.origin.y.approxEqual(caretRect.minY))
    }

    @Test
    func multiLineSuggestionTypesetsOneLinePerBreak() throws {
        textView.setInlineSuggestion("a\nb", at: 0)

        let view = try #require(suggestionViews().first)
        #expect(view.ctLines.count == 2)

        let expectedHeight = textView.layoutManager.estimateLineHeight() * 2
        #expect(view.frame.height.approxEqual(expectedHeight))
    }

    @Test
    func clearRemovesOverlayAndCurrent() throws {
        textView.setInlineSuggestion("suggested", at: 5)
        #expect(suggestionViews().count == 1)

        textView.clearInlineSuggestion()

        #expect(suggestionViews().isEmpty)
        #expect(textView.inlineSuggestionManager?.current == nil)
    }

    @Test
    func emptyTextClearsSuggestion() throws {
        textView.setInlineSuggestion("suggested", at: 5)
        #expect(suggestionViews().count == 1)

        textView.setInlineSuggestion("", at: 5)

        #expect(suggestionViews().isEmpty)
        #expect(textView.inlineSuggestionManager?.current == nil)
    }

    @Test
    func setSuggestionAtPrimaryCaretUsesSelection() throws {
        textView.selectionManager.setSelectedRange(NSRange(location: 3, length: 0))
        textView.setInlineSuggestion("suggested")

        #expect(textView.inlineSuggestionManager?.current == InlineSuggestion(offset: 3, text: "suggested"))
        #expect(suggestionViews().count == 1)
    }

    @Test
    func outOfRangeOffsetAfterEditClearsSafely() throws {
        textView.setInlineSuggestion("suggested", at: textStorage.length)
        #expect(suggestionViews().count == 1)

        // Shrink the document so the anchored offset is now past the end.
        textView.string = "Hi"
        textView.layoutManager.layoutLines()
        textView.inlineSuggestionManager?.updateLayout()

        #expect(suggestionViews().isEmpty)
        #expect(textView.inlineSuggestionManager?.current == nil)
    }
}
