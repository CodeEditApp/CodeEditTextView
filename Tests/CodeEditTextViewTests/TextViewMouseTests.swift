import Testing
import AppKit
@testable import CodeEditTextView

@Suite
@MainActor
struct TextViewMouseTests {
    let textView: TextView

    init() {
        textView = TextView(string: "Lorem Ipsum\nDolor Sit Amet\nConsectetur")
    }

    /// `layout()` resizes the frame to fit its content (there's no enclosing scroll view to take the size from), so
    /// the test frame has to be applied afterwards for the view to be genuinely wider than its insets.
    private func layout(left: CGFloat, right: CGFloat, width: CGFloat = 500) {
        textView.edgeInsets = HorizontalEdgeInsets(left: left, right: right)
        textView.layout()
        textView.frame = NSRect(x: 0, y: 0, width: width, height: 300)
    }

    /// A drag that leaves the leading inset — the strip a gutter is drawn over — must still resolve to a text
    /// offset. Otherwise the layout manager returns `nil` and the in-progress selection stops updating.
    @Test
    func pointOverLeadingInsetResolvesToTextOffset() {
        layout(left: 60, right: 0)

        let overGutter = CGPoint(x: 12, y: 2)
        #expect(textView.layoutManager.textOffsetAtPoint(overGutter) == nil, "Precondition: raw point is unresolvable")

        let clamped = textView.clampToTextArea(overGutter)
        #expect(clamped.x == 60)
        #expect(textView.layoutManager.textOffsetAtPoint(clamped) == 0, "Should resolve to the start of line 1")
    }

    /// Points left of the view entirely — the pointer having been dragged out of the window — clamp the same way.
    @Test
    func pointLeftOfViewResolvesToLineStart() {
        layout(left: 60, right: 0)

        let clamped = textView.clampToTextArea(CGPoint(x: -400, y: 2))
        #expect(clamped.x == 60)
        #expect(textView.layoutManager.textOffsetAtPoint(clamped) == 0)
    }

    @Test
    func pointRightOfViewClampsInsideTrailingInset() {
        layout(left: 60, right: 40)
        #expect(textView.frame.width == 500, "Precondition: the view is wider than its insets")

        let clamped = textView.clampToTextArea(CGPoint(x: 9_000, y: 2))
        #expect(clamped.x == 460)
        #expect(textView.layoutManager.textOffsetAtPoint(clamped) != nil)
    }

    @Test
    func pointInsideTextAreaIsUnchanged() {
        layout(left: 60, right: 40)

        let inside = CGPoint(x: 200, y: 2)
        #expect(textView.clampToTextArea(inside) == inside)
    }

    @Test
    func verticalPositionsClampToTheView() {
        layout(left: 60, right: 0)

        #expect(textView.clampToTextArea(CGPoint(x: 100, y: -500)).y == 0)
        #expect(textView.clampToTextArea(CGPoint(x: 100, y: 9_000)).y == textView.frame.height)
    }

    /// With insets wider than the view, the clamp must not produce an inverted range.
    @Test
    func degenerateInsetsDoNotInvert() {
        layout(left: 60, right: 40, width: 50)

        #expect(textView.clampToTextArea(CGPoint(x: 10, y: 2)).x == 60)
    }

    /// The drag anchor is set on mouse down, not on the first drag event, so a selection starts exactly where the
    /// user pressed rather than wherever the pointer had traveled to by the time the first drag event arrived.
    @Test
    func mouseDownSetsDragAnchor() throws {
        layout(left: 60, right: 0)
        #expect(textView.mouseDragAnchor == nil)

        let event = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: NSPoint(x: 100, y: 2),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
        textView.mouseDown(with: event)

        // The view has no window, so the window→view conversion isn't meaningful enough to assert an exact point;
        // what matters is that the anchor exists before any drag event arrives, and that it's resolvable.
        let anchor = try #require(textView.mouseDragAnchor)
        #expect(textView.layoutManager.textOffsetAtPoint(anchor) != nil)
    }
}
