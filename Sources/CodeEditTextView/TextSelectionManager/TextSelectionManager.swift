//
//  TextSelectionManager.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 7/17/23.
//

import AppKit

public protocol TextSelectionManagerDelegate: AnyObject {
    var visibleTextRange: NSRange? { get }

    func setNeedsDisplay()
    /// Dirties `rect`, expressed in the delegate's own coordinate space. `NSView` satisfies this requirement
    /// with its own method of the same name.
    func setNeedsDisplay(_ rect: NSRect)
    func estimatedLineHeight() -> CGFloat
}

/// Manages an array of text selections representing cursors (0-length ranges) and selections (>0-length ranges).
///
/// Draws selections using a draw method similar to the `TextLayoutManager` class, and adds cursor views when
/// appropriate.
public class TextSelectionManager: NSObject {
    // MARK: - Properties

    // swiftlint:disable:next line_length
    public static let selectionChangedNotification: Notification.Name = Notification.Name("com.CodeEdit.TextSelectionManager.TextSelectionChangedNotification")

    public var insertionPointColor: NSColor = NSColor.labelColor {
        didSet {
            textSelections.compactMap({ $0.view as? CursorView }).forEach { $0.color = insertionPointColor }
        }
    }
    public var highlightSelectedLine: Bool = true
    public var selectedLineBackgroundColor: NSColor = NSColor.selectedTextBackgroundColor.withSystemEffect(.disabled) {
        didSet {
            if selectedLineBackgroundColor != oldValue { delegate?.setNeedsDisplay() }
        }
    }
    public var selectionBackgroundColor: NSColor = NSColor.selectedTextBackgroundColor {
        didSet {
            if selectionBackgroundColor != oldValue { delegate?.setNeedsDisplay() }
        }
    }
    public var useSystemCursor: Bool = false {
        didSet {
            updateSelectionViews()
        }
    }

    /// Determines how far inset to draw selection content.
    public var edgeInsets: HorizontalEdgeInsets = .zero {
        didSet {
            delegate?.setNeedsDisplay()
        }
    }

    internal(set) public var textSelections: [TextSelection] = []
    weak var layoutManager: TextLayoutManager?
    weak var textStorage: NSTextStorage?

    /// Selects in `textStorage` from now on. A selection manager that draws a text view's selections in another view
    /// (a minimap's) needs this when the text view's storage is replaced; it holds the storage weakly.
    public func setTextStorage(_ textStorage: NSTextStorage) {
        self.textStorage = textStorage
    }
    weak var textView: TextView?
    weak var delegate: TextSelectionManagerDelegate?
    var cursorTimer: CursorTimer

    /// The bands the selections painted into as of the last scoped invalidation, in the text view's
    /// coordinates. `nil` means the last invalidation could not resolve the selections' geometry and dirtied
    /// the whole viewport instead, so there is no narrower claim to repaint.
    ///
    /// Held as rects rather than ranges: the layout a range referred to may be gone by the time the next
    /// change lands, and the pixels left behind are at the old *rect*, not the old range.
    var lastInvalidatedSelectionRects: [NSRect]?

    public init(
        layoutManager: TextLayoutManager,
        textStorage: NSTextStorage,
        textView: TextView?,
        delegate: TextSelectionManagerDelegate?,
        useSystemCursor: Bool = false
    ) {
        self.layoutManager = layoutManager
        self.textStorage = textStorage
        self.textView = textView
        self.delegate = delegate
        self.cursorTimer = CursorTimer()
        super.init()
        textSelections = []
        updateSelectionViews()
    }

    // MARK: - Selected Ranges

    /// Set the selected ranges to a single range. Overrides any existing selections.
    ///
    /// Out-of-bounds or negative-length ranges are clamped to the document's bounds.
    /// - Parameter range: The range to set.
    public func setSelectedRange(_ range: NSRange) {
        let range = clampedToDocument(range)
        textSelections.forEach { $0.view?.removeFromSuperview() }
        let selection = TextSelection(range: range)
        selection.suggestedXPos = layoutManager?.rectForOffset(range.location)?.minX
        textSelections = [selection]
        updateSelectionViews()
        // Unconditional: `updateSelectionViews` only reports a change when a *cursor view* moved, so replacing
        // a non-empty selection would otherwise never repaint the highlight it removed or added.
        setNeedsDisplayForSelections()
        NotificationCenter.default.post(Notification(name: Self.selectionChangedNotification, object: self))
    }

    /// Set the selected ranges to new ranges. Overrides any existing selections.
    ///
    /// Duplicate ranges, out-of-bounds ranges, and negative-length ranges are dropped. Intersecting ranges are
    /// merged into a single selection spanning them, upholding the invariant that selections never overlap -
    /// overlapping selections would double-apply edits against a shrunken document.
    /// - Parameter range: The selected ranges to set.
    public func setSelectedRanges(_ ranges: [NSRange]) {
        let oldRanges = textSelections.map(\.range)

        textSelections.forEach { $0.view?.removeFromSuperview() }
        // Remove duplicates, invalid ranges, update suggested X position.
        let documentRange = 0...(textStorage?.length ?? 0)
        let sortedRanges = Set(ranges)
            .filter {
                $0.length >= 0 && documentRange.contains($0.location) && documentRange.contains($0.max)
            }
            .sorted(by: { lhs, rhs in
                // Sort longer ranges first at equal locations so a caret at a selection's start merges into it.
                lhs.location != rhs.location ? lhs.location < rhs.location : lhs.length > rhs.length
            })
        // Classic interval merge. Ranges that share at least one character (or a caret inside a selection)
        // collapse into one; touching-but-disjoint ranges and distinct carets are kept separate.
        var mergedRanges: [NSRange] = []
        mergedRanges.reserveCapacity(sortedRanges.count)
        for range in sortedRanges {
            if let last = mergedRanges.last, range.location < last.max {
                mergedRanges[mergedRanges.count - 1] = NSRange(
                    start: last.location,
                    end: max(last.max, range.max)
                )
            } else {
                mergedRanges.append(range)
            }
        }
        textSelections = mergedRanges
            .map {
                let selection = TextSelection(range: $0)
                selection.suggestedXPos = layoutManager?.rectForOffset($0.location)?.minX
                return selection
            }
        updateSelectionViews()
        setNeedsDisplayForSelections()

        if oldRanges != textSelections.map(\.range) {
            NotificationCenter.default.post(Notification(name: Self.selectionChangedNotification, object: self))
        }
    }

    /// Append a new selected range to the existing ones.
    ///
    /// Any existing selections the new range intersects or borders are merged into a single selection spanning
    /// all of them, so selections never overlap.
    /// - Parameter range: The new range to add.
    public func addSelectedRange(_ range: NSRange) {
        let range = clampedToDocument(range)
        guard !textSelections.contains(where: { $0.range == range }) else {
            // Duplicate range, ignore
            return
        }

        var mergedSelection: TextSelection?
        var idx = 0
        while idx < textSelections.count {
            let textSelection = textSelections[idx]
            if (range.length > 0 && textSelection.range.intersection(range) != nil)
                || textSelection.range.max == range.location {
                // Range intersects an existing range. Merge every intersecting selection into one so overlapping
                // selections never coexist.
                if let mergedSelection {
                    mergedSelection.range.formUnion(textSelection.range)
                    textSelection.view?.removeFromSuperview()
                    textSelections.remove(at: idx)
                    continue
                } else {
                    textSelection.range.formUnion(range)
                    mergedSelection = textSelection
                }
            }
            idx += 1
        }
        if mergedSelection == nil {
            textSelections.append(TextSelection(range: range))
        }
        textSelections.sort(by: { $0.range.location < $1.range.location })

        updateSelectionViews()
        NotificationCenter.default.post(Notification(name: Self.selectionChangedNotification, object: self))
        setNeedsDisplayForSelections()
    }

    /// Clamps an externally-supplied range to the document's bounds, normalizing negative lengths to an empty
    /// range so an invalid range can never become a live selection.
    /// - Parameter range: The range to clamp.
    /// - Returns: A range guaranteed to lie inside the document.
    private func clampedToDocument(_ range: NSRange) -> NSRange {
        let documentLength = textStorage?.length ?? 0
        let location = min(max(range.location, 0), documentLength)
        let length = min(max(range.length, 0), documentLength - location)
        return NSRange(location: location, length: length)
    }

    // MARK: - Selection Views

    /// Update all selection cursors. Placing them in the correct position for each text selection and
    /// optionally reseting the blink timer.
    ///
    /// Cursor views only exist while the text view is first responder, but `boundingRect` bookkeeping runs
    /// unconditionally so scroll-to-visible works for selections set while the view isn't focused.
    public func updateSelectionViews(force: Bool = false, skipTimerReset: Bool = false) {
        let showCursorViews = textView?.isFirstResponder ?? false
        var didUpdate: Bool = false

        for textSelection in textSelections {
            if textSelection.range.isEmpty {
                let cursorUpdated = if showCursorViews {
                    repositionCursorSelection(textSelection: textSelection)
                } else {
                    updateCursorBoundingRect(textSelection: textSelection)
                }
                didUpdate = cursorUpdated || didUpdate
            } else if !textSelection.range.isEmpty && textSelection.view != nil {
                textSelection.view?.removeFromSuperview()
                textSelection.view = nil
                didUpdate = true
            }
        }

        if didUpdate || force {
            setNeedsDisplayForSelections()
            if showCursorViews && !skipTimerReset {
                cursorTimer.resetTimer()
                resetSystemCursorTimers()
            }
        }
    }

    /// Updates the cached `boundingRect` for a caret without creating or moving any cursor view. Used while the
    /// text view isn't first responder so programmatic selection changes still track their visual position.
    private func updateCursorBoundingRect(textSelection: TextSelection) -> Bool {
        guard let cursorRect = layoutManager?.rectForOffset(textSelection.range.location) else {
            return false
        }
        let newRect = CGRect(origin: cursorRect.origin, size: CGSize(width: 1, height: cursorRect.height))
        guard textSelection.boundingRect != newRect else {
            return false
        }
        textSelection.boundingRect = newRect
        return true
    }

    private func repositionCursorSelection(textSelection: TextSelection) -> Bool {
        guard let cursorRect = layoutManager?.rectForOffset(textSelection.range.location) else {
            return false
        }

        var doesViewNeedReposition: Bool

        // If using the system cursor, macOS will change the origin and height by about 0.5, so we do an
        // approximate equals in that case to avoid extra updates.
        if useSystemCursor, #available(macOS 14.0, *) {
            doesViewNeedReposition = !textSelection.boundingRect.origin.approxEqual(cursorRect.origin)
            || !textSelection.boundingRect.height.approxEqual(layoutManager?.estimateLineHeight() ?? 0)
        } else {
            doesViewNeedReposition = textSelection.boundingRect.origin != cursorRect.origin
            || textSelection.boundingRect.height != layoutManager?.estimateLineHeight() ?? 0
        }

        if textSelection.view == nil || doesViewNeedReposition {
            let cursorView: NSView

            if let existingCursorView = textSelection.view {
                cursorView = existingCursorView
            } else {
                textSelection.view?.removeFromSuperview()
                textSelection.view = nil

                if useSystemCursor, #available(macOS 14.0, *) {
                    let systemCursorView = NSTextInsertionIndicator(frame: .zero)
                    cursorView = systemCursorView
                    systemCursorView.displayMode = .automatic
                } else {
                    let internalCursorView = CursorView(color: insertionPointColor)
                    cursorView = internalCursorView
                    cursorTimer.register(internalCursorView)
                }

                textView?.addSubview(cursorView, positioned: .above, relativeTo: nil)
            }

            cursorView.frame.origin = cursorRect.origin
            cursorView.frame.size.height = cursorRect.height

            textSelection.view = cursorView
            textSelection.boundingRect = cursorView.frame

            return true
        }

        return false
    }

    func resetSystemCursorTimers() {
        guard #available(macOS 14, *) else { return }
        for cursorView in textSelections.compactMap({ $0.view as? NSTextInsertionIndicator }) {
            let frame = cursorView.frame
            cursorView.frame = .zero
            cursorView.frame = frame
        }
    }

    /// Get the height for a cursor placed at the beginning of the given range.
    /// - Parameter range: The range the cursor is at.
    /// - Returns: The height the cursor should be to match the text at that location.
    fileprivate func heightForCursorAt(_ range: NSRange) -> CGFloat? {
        guard let selectedLine = layoutManager?.textLineForOffset(range.location) else {
            return layoutManager?.estimateLineHeight()
        }
        return selectedLine
            .data
            .lineFragments
            .getLine(atOffset: range.location - (selectedLine.range.location))?
            .height
        ?? layoutManager?.estimateLineHeight()
    }

    /// Removes all cursor views and stops the cursor blink timer.
    func removeCursors() {
        cursorTimer.stopTimer()
        for textSelection in textSelections {
            textSelection.view?.removeFromSuperview()
        }
    }
}
