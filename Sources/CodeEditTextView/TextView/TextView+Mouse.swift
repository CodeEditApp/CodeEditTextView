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

    override public func mouseUp(with event: NSEvent) {
        mouseDragAnchor = nil
        disableMouseAutoscrollTimer()
        super.mouseUp(with: event)
    }

    override public func mouseDragged(with event: NSEvent) {
        guard !(inputContext?.handleEvent(event) ?? false) && isSelectable && !isDragging else {
            return
        }

        if mouseDragAnchor == nil {
            mouseDragAnchor = convert(event.locationInWindow, from: nil)
            super.mouseDragged(with: event)
        } else {
            guard let mouseDragAnchor,
                  let startPosition = layoutManager.textOffsetAtPoint(mouseDragAnchor),
                  let endPosition = layoutManager.textOffsetAtPoint(convert(event.locationInWindow, from: nil)) else {
                return
            }

            let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifierFlags.contains(.option) {
                dragColumnSelection(mouseDragAnchor: mouseDragAnchor, event: event)
            } else {
                dragSelection(startPosition: startPosition, endPosition: endPosition, mouseDragAnchor: mouseDragAnchor)
            }

            setNeedsDisplay()
            self.autoscroll(with: event)
        }
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

    private func dragColumnSelection(mouseDragAnchor: CGPoint, event: NSEvent) {
        // Drag the selection and select in columns
        let eventLocation = convert(event.locationInWindow, from: nil)

        let start = CGPoint(
            x: min(mouseDragAnchor.x, eventLocation.x),
            y: min(mouseDragAnchor.y, eventLocation.y)
        )
        let end = CGPoint(
            x: max(mouseDragAnchor.x, eventLocation.x),
            y: max(mouseDragAnchor.y, eventLocation.y)
        )

        // Collect all overlapping text ranges
        var selectedRanges: [NSRange] = layoutManager.linesStartingAt(start.y, until: end.y).flatMap { textLine in
            // Collect fragment ranges
            return textLine.data.lineFragments.compactMap { lineFragment -> NSRange? in
                let startOffset = self.layoutManager.textOffsetAtPoint(
                    start,
                    fragmentPosition: lineFragment,
                    linePosition: textLine
                )
                let endOffset = self.layoutManager.textOffsetAtPoint(
                    end,
                    fragmentPosition: lineFragment,
                    linePosition: textLine
                )
                guard let startOffset, let endOffset else { return nil }

                return NSRange(start: startOffset, end: endOffset)
            }
        }

        // If we have some non-cursor selections, filter out any cursor selections
        if selectedRanges.contains(where: { !$0.isEmpty }) {
            selectedRanges = selectedRanges.filter({ !$0.isEmpty })
        }

        selectionManager.setSelectedRanges(selectedRanges)
    }
}
