import Testing
import AppKit
@testable import CodeEditTextView

@Suite
@MainActor
struct TextViewTests {
    class MockDelegate: TextViewDelegate {
        var shouldReplaceContents: ((_ textView: TextView, _ range: NSRange, _ string: String) -> Bool)?

        func textView(_ textView: TextView, shouldReplaceContentsIn range: NSRange, with string: String) -> Bool {
            shouldReplaceContents?(textView, range, string) ?? true
        }
    }

    let textView: TextView
    let delegate: MockDelegate

    init() {
        textView = TextView(string: "Lorem Ipsum")
        delegate = MockDelegate()
        textView.delegate = delegate
    }

    @Test
    func delegateChangesText() {
        var hasReplaced = false
        delegate.shouldReplaceContents = { textView, _, _ -> Bool in
            if !hasReplaced {
                hasReplaced.toggle()
                textView.replaceCharacters(in: NSRange(location: 0, length: 0), with: " World ")
            }

            return true
        }

        textView.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Hello")

        #expect(textView.string == "Hello World Lorem Ipsum")
        // available in test module
        textView.layoutManager.lineStorage.validateInternalState()
    }
}
