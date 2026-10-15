//
//  TextView+Drag.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 10/20/23.
//

import Foundation
import AppKit

private let pasteboardObjects = [NSString.self, NSURL.self]

extension TextView: NSDraggingSource {
    // MARK: - Drag Gesture

    /// Custom press gesture recognizer that fails if it does not click into a selected range.
    private class DragSelectionGesture: NSPressGestureRecognizer {
        override func mouseDown(with event: NSEvent) {
            guard isEnabled, let view = self.view as? TextView, event.type == .leftMouseDown else {
                return
            }

            let clickPoint = view.convert(event.locationInWindow, from: nil)
            if view.shouldFailDragGesture(at: clickPoint) {
                state = .failed
            }

            super.mouseDown(with: event)
        }
    }

    /// Whether a mouse-down at the given point must fail the drag-selection gesture.
    ///
    /// `isSelectable` can change after the gesture is created, so it is checked per-event here rather than
    /// mirrored into the recognizer's `isEnabled`. A click also fails the gesture unless it lands inside one of
    /// the current selections' fill rects.
    func shouldFailDragGesture(at clickPoint: CGPoint) -> Bool {
        guard isSelectable else { return true }
        let selectionRects = selectionManager.textSelections.filter({ !$0.range.isEmpty }).flatMap {
            selectionManager.getFillRects(in: frame, for: $0)
        }
        return !selectionRects.contains(where: { $0.contains(clickPoint) })
    }

    /// Adds a gesture for recognizing selection dragging gestures to the text view.
    /// See ``TextView/DragSelectionGesture`` for details.
    func setUpDragGesture() {
        let dragGesture = DragSelectionGesture(target: self, action: #selector(dragGestureHandler(_:)))
        dragGesture.minimumPressDuration = NSEvent.doubleClickInterval / 3
        addGestureRecognizer(dragGesture)
    }

    /// Handles state change on the drag and drop gesture recognizer.
    ///
    /// This will ignore any gesture state besides `.began`, and will end by setting the state to `.ended`. The gesture
    /// is only meant to handle *recognizing* the drag, but the system drag interaction handles the rest.
    ///
    /// This will create a ``DraggingTextRenderer`` with the contents of the visible text selection. That is converted
    /// into an image and given to a new dragging session on the text view
    ///
    /// The rest of the drag interaction is handled by ``performDragOperation(_:)``, ``draggingUpdated(_:)``,
    /// ``draggingSession(_:willBeginAt:)`` and family.
    ///
    /// - Parameter sender: The gesture that's sending the state change.
    @objc private func dragGestureHandler(_ sender: DragSelectionGesture) {
        guard sender.state == .began else { return }
        defer {
            sender.state = .ended
        }

        guard let visibleTextRange,
              let draggingView = DraggingTextRenderer(
                ranges: selectionManager.textSelections
                    .sorted(using: KeyPathComparator(\.range.location))
                    .compactMap { $0.range.intersection(visibleTextRange) },
                layoutManager: layoutManager
              ) else {
            return
        }

        guard let bitmap = bitmapImageRepForCachingDisplay(in: draggingView.frame) else {
            return
        }

        draggingView.cacheDisplay(in: draggingView.bounds, to: bitmap)

        guard let cgImage = bitmap.cgImage else {
            return
        }

        let draggingImage = NSImage(cgImage: cgImage, size: draggingView.intrinsicContentSize)

        let attributedStrings = selectionManager
            .textSelections
            .sorted(by: { $0.range.location < $1.range.location })
            .map { textStorage.attributedSubstring(from: $0.range) }
        let attributedString = NSMutableAttributedString()
        for (idx, string) in attributedStrings.enumerated() {
            attributedString.append(string)
            if idx < attributedStrings.count - 1 {
                attributedString.append(NSAttributedString(string: layoutManager.detectedLineEnding.rawValue))
            }
        }

        let draggingItem = NSDraggingItem(pasteboardWriter: attributedString)
        draggingItem.setDraggingFrame(draggingView.frame, contents: draggingImage)

        guard let currentEvent = NSApp.currentEvent else {
            return
        }

        beginDraggingSession(with: [draggingItem], event: currentEvent, source: self)
    }

    // MARK: - NSDraggingSource

    public func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .outsideApplication ? .copy : .move
    }

    public func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        removeDraggingCursor()
        isDragging = true
        dragHandledInSelf = false
        // No mouse-drag events are delivered during a dragging session; autoscroll is driven by
        // ``draggingUpdated(_:)`` instead of the mouse autoscroll timer.
        disableMouseAutoscrollTimer()
    }

    public func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        dragSessionEnded(operation: operation)
        removeDraggingCursor()
        isDragging = false
        disableMouseAutoscrollTimer()
    }

    /// Source-side cleanup when a dragging session ends.
    ///
    /// A `.move` dropped into a *different* view inserts the text at the destination; the source view is
    /// responsible for deleting the dragged selection - mirroring `NSTextView`. Same-view drops (including
    /// rejected self-drops) set ``TextView/dragHandledInSelf`` in ``performDragOperation(_:)`` and handle any
    /// deletion there, so this must not delete again.
    /// - Parameter operation: The drag operation the destination performed.
    func dragSessionEnded(operation: NSDragOperation) {
        defer { dragHandledInSelf = false }
        guard operation == .move, !dragHandledInSelf, isEditable else { return }
        let draggedRanges = selectionManager.textSelections.map(\.range).filter { !$0.isEmpty }
        guard !draggedRanges.isEmpty else { return }
        replaceCharacters(in: draggedRanges, with: "")
    }

    // MARK: - NSDraggingDestination

    override public func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let operation = determineDragOperation(sender)
        updateDropCursor(sender, operation: operation)
        return operation
    }

    /// Updates the ``TextView/draggingCursorView`` insertion cursor to match the drop destination and scrolls the
    /// view when the drag nears the viewport's edge.
    ///
    /// This runs on the dragging *destination*, so it works for drags that originated in other views or other
    /// applications. AppKit sends this periodically even when the pointer is stationary, which drives autoscroll;
    /// no mouse-dragged events are delivered while a dragging session is active.
    override public func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let operation = determineDragOperation(sender)
        updateDropCursor(sender, operation: operation)
        if !operation.isEmpty {
            autoscrollDuringDrag(to: convert(sender.draggingLocation, from: nil))
        }
        return operation
    }

    override public func draggingExited(_ sender: (any NSDraggingInfo)?) {
        removeDraggingCursor()
    }

    override public func draggingEnded(_ sender: any NSDraggingInfo) {
        removeDraggingCursor()
    }

    private func determineDragOperation(_ dragInfo: any NSDraggingInfo) -> NSDragOperation {
        guard isEditable else {
            return NSDragOperation()
        }

        let canReadObjects = dragInfo.draggingPasteboard.canReadObject(forClasses: pasteboardObjects)

        guard canReadObjects else {
            return NSDragOperation()
        }

        if let currentEvent = NSApplication.shared.currentEvent, currentEvent.modifierFlags.contains(.option) {
            return .copy
        }

        return .move
    }

    /// Places or hides the drop-insertion cursor for a drag hovering at the dragging info's location.
    ///
    /// The text view will not place a dragging cursor when the drag comes from this view and hovers over one of
    /// its own selections.
    private func updateDropCursor(_ dragInfo: any NSDraggingInfo, operation: NSDragOperation) {
        let point = convert(dragInfo.draggingLocation, from: nil)
        guard !operation.isEmpty,
              let documentOffset = layoutManager.textOffsetAtPoint(point),
              let cursorPosition = layoutManager.rectForOffset(documentOffset),
              !(isSourceOfDrag(dragInfo)
                && selectionManager.textSelections.contains(where: { $0.range.contains(documentOffset) })) else {
            removeDraggingCursor()
            return
        }

        let cursor: NSView

        if let draggingCursorView {
            cursor = draggingCursorView
        } else if useSystemCursor, #available(macOS 15, *) {
            let systemCursor = NSTextInsertionIndicator()
            cursor = systemCursor
            systemCursor.displayMode = .visible
            addSubview(cursor)
            draggingCursorView = cursor
        } else {
            cursor = CursorView(color: selectionManager.insertionPointColor)
            addSubview(cursor)
            draggingCursorView = cursor
        }

        cursor.frame.origin = cursorPosition.origin
        cursor.frame.size.height = cursorPosition.height
    }

    private func removeDraggingCursor() {
        draggingCursorView?.removeFromSuperview()
        draggingCursorView = nil
    }

    private func isSourceOfDrag(_ dragInfo: any NSDraggingInfo) -> Bool {
        (dragInfo.draggingSource as? TextView) === self
    }

    /// Scrolls the view towards a drag location as it approaches the visible rect's edges.
    private func autoscrollDuringDrag(to point: CGPoint) {
        let margin: CGFloat = 24.0
        scrollToVisible(CGRect(x: point.x - margin, y: point.y - margin, width: margin * 2, height: margin * 2))
    }

    // MARK: - Perform Drag

    /// Performs the final drop operation.
    ///
    /// This method accepts a number of items from the dragging info's pasteboard, and inserts them at the drop
    /// location. If the drag originated in this view, the dragged text is moved.
    ///
    /// If the app's current event has the `option` key pressed, this will only paste the text from the pasteboard,
    /// and not remove the original dragged text.
    ///
    /// - Parameter sender: The dragging info to use.
    /// - Returns: `true`, if the drag was accepted.
    override public func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        removeDraggingCursor()

        // Record self-drops before any early return: when this view is both source and destination, the
        // session-ended callback must never delete the dragged text (that's handled - or intentionally
        // skipped - right here).
        if isSourceOfDrag(sender) {
            dragHandledInSelf = true
        }

        guard isEditable else {
            return false
        }

        guard let objects = sender.draggingPasteboard.readObjects(forClasses: pasteboardObjects)?
            .compactMap({ anyObject in
                if let object = anyObject as? NSString {
                    return String(object)
                } else if let object = anyObject as? NSURL, let string = object.absoluteString {
                    return String(string)
                }
                return nil
            }),
              objects.count > 0 else {
            return false
        }
        let insertionString = objects.joined(separator: layoutManager.detectedLineEnding.rawValue)

        // Resolve the insertion location from the drop point itself so drops from other views and applications
        // land under the pointer.
        guard var insertionOffset = layoutManager.textOffsetAtPoint(
            convert(sender.draggingLocation, from: nil)
        ) else {
            return false
        }

        let sourceIsSelf = isSourceOfDrag(sender)

        // Dropping a selection onto itself is a no-op.
        if sourceIsSelf && selectionManager.textSelections.contains(where: { $0.range.contains(insertionOffset) }) {
            return false
        }

        let shouldCutSourceText = sourceIsSelf
            && !(NSApplication.shared.currentEvent?.modifierFlags.contains(.option) ?? false)

        undoManager?.beginUndoGrouping()

        if shouldCutSourceText {
            insertionOffset = insertionOffsetAfterCuttingSelections(from: insertionOffset)
            insertText("") // Replace the selected ranges with nothing
        }

        replaceCharacters(in: [NSRange(location: insertionOffset, length: 0)], with: insertionString)

        undoManager?.endUndoGrouping()

        let selectionLocation = min(insertionOffset, textStorage.length)
        let selectionLength = min((insertionString as NSString).length, textStorage.length - selectionLocation)
        selectionManager.setSelectedRange(NSRange(location: selectionLocation, length: selectionLength))

        return true
    }

    /// Offsets a same-view drop location by the selected text about to be cut before it, so the insertion lands
    /// where the user dropped once the dragged selections are removed.
    private func insertionOffsetAfterCuttingSelections(from insertionOffset: Int) -> Int {
        var updatedInsertionOffset = insertionOffset
        for selection in selectionManager.textSelections.reversed()
        where selection.range.location < insertionOffset {
            if selection.range.upperBound > insertionOffset {
                updatedInsertionOffset -= insertionOffset - selection.range.location
            } else {
                updatedInsertionOffset -= selection.range.length
            }
        }
        return updatedInsertionOffset
    }
}
