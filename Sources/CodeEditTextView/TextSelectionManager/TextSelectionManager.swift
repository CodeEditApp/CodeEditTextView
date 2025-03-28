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
    public var selectedLineBackgroundColor: NSColor = NSColor.selectedTextBackgroundColor.withSystemEffect(.disabled)
    public var selectionBackgroundColor: NSColor = NSColor.selectedTextBackgroundColor
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
    weak var textView: TextView?
    weak var delegate: TextSelectionManagerDelegate?
    var cursorTimer: CursorTimer

    init(
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
    /// - Parameter range: The range to set.
    public func setSelectedRange(_ range: NSRange) {
        textSelections.forEach { $0.view?.removeFromSuperview() }
        let selection = TextSelection(range: range)
        selection.suggestedXPos = layoutManager?.rectForOffset(range.location)?.minX
        textSelections = [selection]
        updateSelectionViews()
        NotificationCenter.default.post(Notification(name: Self.selectionChangedNotification, object: self))
        delegate?.setNeedsDisplay()
    }

    /// Set the selected ranges to new ranges. Overrides any existing selections.
    /// - Parameter range: The selected ranges to set.
    public func setSelectedRanges(_ ranges: [NSRange]) {
        textSelections.forEach { $0.view?.removeFromSuperview() }
        // Remove duplicates, invalid ranges, update suggested X position.
        textSelections = Set(ranges)
            .filter {
                (0...(textStorage?.length ?? 0)).contains($0.location)
                && (0...(textStorage?.length ?? 0)).contains($0.max)
            }
            .map {
                let selection = TextSelection(range: $0)
                selection.suggestedXPos = layoutManager?.rectForOffset($0.location)?.minX
                return selection
            }
        updateSelectionViews()
        NotificationCenter.default.post(Notification(name: Self.selectionChangedNotification, object: self))
        delegate?.setNeedsDisplay()
    }

    /// Append a new selected range to the existing ones.
    /// - Parameter range: The new range to add.
    public func addSelectedRange(_ range: NSRange) {
        let newTextSelection = TextSelection(range: range)
        var didHandle = false
        for textSelection in textSelections {
            if textSelection.range == newTextSelection.range {
                // Duplicate range, ignore
                return
            } else if (range.length > 0 && textSelection.range.intersection(range) != nil)
                        || textSelection.range.max == range.location {
                // Range intersects existing range, modify this range to be the union of both and don't add the new
                // selection
                textSelection.range = textSelection.range.union(range)
                didHandle = true
            }
        }
        if !didHandle {
            textSelections.append(newTextSelection)
        }

        updateSelectionViews()
        NotificationCenter.default.post(Notification(name: Self.selectionChangedNotification, object: self))
        delegate?.setNeedsDisplay()
    }

    // MARK: - Selection Views

    /// Update all selection cursors. Placing them in the correct position for each text selection and reseting the
    /// blink timer.
    func updateSelectionViews() {
        var didUpdate: Bool = false

        for textSelection in textSelections {
            if textSelection.range.isEmpty {
                let cursorOrigin = (layoutManager?.rectForOffset(textSelection.range.location) ?? .zero).origin

                var doesViewNeedReposition: Bool

                // If using the system cursor, macOS will change the origin and height by about 0.5, so we do an
                // approximate equals in that case to avoid extra updates.
                if useSystemCursor, #available(macOS 14.0, *) {
                    doesViewNeedReposition = !textSelection.boundingRect.origin.approxEqual(cursorOrigin)
                    || !textSelection.boundingRect.height.approxEqual(layoutManager?.estimateLineHeight() ?? 0)
                } else {
                    doesViewNeedReposition = textSelection.boundingRect.origin != cursorOrigin
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

                        textView?.addSubview(cursorView)
                    }

                    cursorView.frame.origin = cursorOrigin
                    cursorView.frame.size.height = heightForCursorAt(textSelection.range) ?? 0

                    textSelection.view = cursorView
                    textSelection.boundingRect = cursorView.frame

                    didUpdate = true
                }
            } else if !textSelection.range.isEmpty && textSelection.view != nil {
                textSelection.view?.removeFromSuperview()
                textSelection.view = nil
                didUpdate = true
            }
        }

        if didUpdate {
            delegate?.setNeedsDisplay()
            cursorTimer.resetTimer()
            resetSystemCursorTimers()
        }
    }

    private func resetSystemCursorTimers() {
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
