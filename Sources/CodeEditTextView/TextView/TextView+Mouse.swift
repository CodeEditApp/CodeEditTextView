//
//  TextView+Mouse.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 9/19/23.
//

import AppKit

extension TextView {
    override public func mouseDown(with event: NSEvent) {
        // Set cursor
        guard isSelectable,
              event.type == .leftMouseDown,
              let offset = layoutManager.textOffsetAtPoint(self.convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event)
            return
        }

        if let content = layoutManager.contentRun(at: offset),
           case let .attachment(attachment) = content.data, event.clickCount < 3 {
            handleAttachmentClick(event: event, offset: offset, attachment: attachment)
            return
        }

        switch event.clickCount {
        case 1:
            handleSingleClick(event: event, offset: offset)
        case 2:
            handleDoubleClick(event: event)
        case 3:
            handleTripleClick(event: event)
        default:
            break
        }

        // Anchor the drag at the press location. Waiting for the first drag event to set this anchors the selection
        // wherever the pointer had already traveled to by then, which reads as the selection starting a character or
        // two away from where the user clicked.
        mouseDragAnchor = clampToTextArea(convert(event.locationInWindow, from: nil))

        setUpMouseAutoscrollTimer()
    }

    /// Single click, if control-shift we add a cursor
    /// if shift, we extend the selection to the click location
    /// else we set the cursor
    fileprivate func handleSingleClick(event: NSEvent, offset: Int) {
        cursorSelectionMode = .character

        guard isEditable else {
            super.mouseDown(with: event)
            return
        }
        let eventFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if eventFlags == [.control, .shift] {
            unmarkText()
            selectionManager.addSelectedRange(NSRange(location: offset, length: 0))
        } else if eventFlags.contains(.shift) {
            unmarkText()
            shiftClickExtendSelection(to: offset)
        } else {
            selectionManager.setSelectedRange(NSRange(location: offset, length: 0))
            unmarkTextIfNeeded()
        }
    }

    fileprivate func handleDoubleClick(event: NSEvent) {
        cursorSelectionMode = .word

        guard !event.modifierFlags.contains(.shift) else {
            super.mouseDown(with: event)
            return
        }
        unmarkText()
        selectWord(nil)
    }

    fileprivate func handleTripleClick(event: NSEvent) {
        cursorSelectionMode = .line

        guard !event.modifierFlags.contains(.shift) else {
            super.mouseDown(with: event)
            return
        }
        unmarkText()
        selectLine(nil)
    }

    fileprivate func handleAttachmentClick(event: NSEvent, offset: Int, attachment: AnyTextAttachment) {
        switch event.clickCount {
        case 1:
            selectionManager.setSelectedRange(attachment.range)
        case 2:
            performAttachmentAction(attachment: attachment)
        default:
            break
        }
    }

    func performAttachmentAction(attachment: AnyTextAttachment) {
        let action = attachment.attachment.attachmentAction()
        switch action {
        case .none:
            return
        case .discard:
            layoutManager.attachments.remove(atOffset: attachment.range.location)
            selectionManager.setSelectedRange(NSRange(location: attachment.range.location, length: 0))
        case let .replace(text):
            replaceCharacters(in: attachment.range, with: text)
        }
    }

    override public func mouseUp(with event: NSEvent) {
        mouseDragAnchor = nil
        disableMouseAutoscrollTimer()
        super.mouseUp(with: event)
    }

    override public func mouseDragged(with event: NSEvent) {
        guard !(inputContext?.handleEvent(event) ?? false) && isSelectable && !isDragging else {
            return
        }

        // We receive global events because our view received the drag event, but we need to clamp the potentially
        // out-of-bounds positions to a position our layout manager can deal with.
        let locationInView = clampToTextArea(convert(event.locationInWindow, from: nil))

        if mouseDragAnchor == nil {
            mouseDragAnchor = locationInView
            super.mouseDragged(with: event)
        } else {
            guard let mouseDragAnchor,
                  let startPosition = layoutManager.textOffsetAtPoint(mouseDragAnchor),
                  let endPosition = layoutManager.textOffsetAtPoint(locationInView) else {
                return
            }

            let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifierFlags.contains(.option) {
                dragColumnSelection(mouseDragAnchor: mouseDragAnchor, locationInView: locationInView)
            } else {
                dragSelection(startPosition: startPosition, endPosition: endPosition, mouseDragAnchor: mouseDragAnchor)
            }

            setNeedsDisplay()
            self.autoscroll(with: event)
        }
    }

    /// Clamps a point to the region ``TextLayoutManager/textOffsetAtPoint(_:)`` can resolve into a text offset.
    ///
    /// Drag events are delivered in global coordinates, so the point can lie well outside the view. The horizontal
    /// bounds also have to respect ``TextLayoutManager/edgeInsets``: text is laid out inset from the view's edges, and
    /// any position left of the leading inset — the strip a gutter is drawn over, for instance — resolves to `nil`.
    ///
    /// A `nil` offset mid-drag strands the selection at its last resolvable value, so the selection stops responding
    /// entirely while the pointer sits over the gutter. Clamping into the inset region instead maps those positions to
    /// the start of a line, which is what AppKit does.
    func clampToTextArea(_ point: CGPoint) -> CGPoint {
        let insets = layoutManager.edgeInsets
        let minX = insets.left
        let maxX = max(minX, frame.width - insets.right)
        return CGPoint(
            x: min(max(point.x, minX), maxX),
            y: min(max(point.y, 0.0), frame.height)
        )
    }

    /// Extends the current selection to the offset. Only used when the user shift-clicks a location in the document.
    ///
    /// If the offset is within the selection, trims the selection from the nearest edge (start or end) towards the
    /// clicked offset.
    /// Otherwise, extends the selection to the clicked offset.
    ///
    /// - Parameter offset: The offset clicked on.
    fileprivate func shiftClickExtendSelection(to offset: Int) {
        // Use the last added selection, this is behavior copied from Xcode.
        guard var selectedRange = selectionManager.textSelections.last?.range else { return }
        if selectedRange.contains(offset) {
            if offset - selectedRange.location <= selectedRange.max - offset {
                selectedRange.length -= offset - selectedRange.location
                selectedRange.location = offset
            } else {
                selectedRange.length -= selectedRange.max - offset
            }
        } else {
            selectedRange.formUnion(NSRange(
                start: min(offset, selectedRange.location),
                end: max(offset, selectedRange.max)
            ))
        }
        selectionManager.setSelectedRange(selectedRange)
        setNeedsDisplay()
    }

    // MARK: - Mouse Autoscroll

    /// Sets up a timer that fires at a predetermined period to autoscroll the text view.
    /// Ensure the timer is disabled using ``disableMouseAutoscrollTimer``.
    func setUpMouseAutoscrollTimer() {
        mouseDragTimer?.invalidate()
        // https://cocoadev.github.io/AutoScrolling/ (fired at ~45Hz)
        mouseDragTimer = Timer.scheduledTimer(withTimeInterval: 0.022, repeats: true) { [weak self] _ in
            if let event = self?.window?.currentEvent, event.type == .leftMouseDragged {
                self?.mouseDragged(with: event)
                self?.autoscroll(with: event)
            }
        }
    }

    /// Disables the mouse drag timer started by ``setUpMouseAutoscrollTimer``
    func disableMouseAutoscrollTimer() {
        mouseDragTimer?.invalidate()
        mouseDragTimer = nil
    }

    // MARK: - Drag Selection

    private func dragSelection(startPosition: Int, endPosition: Int, mouseDragAnchor: CGPoint) {
        switch cursorSelectionMode {
        case .character:
            selectionManager.setSelectedRange(
                NSRange(
                    location: min(startPosition, endPosition),
                    length: max(startPosition, endPosition) - min(startPosition, endPosition)
                )
            )

        case .word:
            let startWordRange = findWordBoundary(at: startPosition)
            let endWordRange = findWordBoundary(at: endPosition)

            selectionManager.setSelectedRange(
                NSRange(
                    location: min(startWordRange.location, endWordRange.location),
                    length: max(startWordRange.location + startWordRange.length,
                                endWordRange.location + endWordRange.length) -
                    min(startWordRange.location, endWordRange.location)
                )
            )

        case .line:
            let startLineRange = findLineBoundary(at: startPosition)
            let endLineRange = findLineBoundary(at: endPosition)

            selectionManager.setSelectedRange(
                NSRange(
                    location: min(startLineRange.location, endLineRange.location),
                    length: max(startLineRange.location + startLineRange.length,
                                endLineRange.location + endLineRange.length) -
                    min(startLineRange.location, endLineRange.location)
                )
            )
        }
    }

    private func dragColumnSelection(mouseDragAnchor: CGPoint, locationInView: CGPoint) {
        selectColumns(betweenPointA: mouseDragAnchor, pointB: locationInView)
    }
}
