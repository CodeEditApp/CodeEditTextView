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
            // Single click, if control-shift we add a cursor
            // if shift, we extend the selection to the click location
            // else we set the cursor
            guard isEditable else {
                super.mouseDown(with: event)
                return
            }
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSuperset(of: [.control, .shift]) {
                unmarkText()
                selectionManager.addSelectedRange(NSRange(location: offset, length: 0))
            } else if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift) {
                unmarkText()
                shiftClickExtendSelection(to: offset)
            } else {
                selectionManager.setSelectedRange(NSRange(location: offset, length: 0))
                unmarkTextIfNeeded()
            }
        case 2:
            guard !event.modifierFlags.contains(.shift) else {
                super.mouseDown(with: event)
                return
            }
            unmarkText()
            selectWord(nil)
        case 3:
            guard !event.modifierFlags.contains(.shift) else {
                super.mouseDown(with: event)
                return
            }
            unmarkText()
            selectLine(nil)
        default:
            break
        }

        mouseDragTimer?.invalidate()
        // https://cocoadev.github.io/AutoScrolling/ (fired at ~45Hz)
        mouseDragTimer = Timer.scheduledTimer(withTimeInterval: 0.022, repeats: true) { [weak self] _ in
            if let event = self?.window?.currentEvent, event.type == .leftMouseDragged {
                self?.mouseDragged(with: event)
                self?.autoscroll(with: event)
            }
        }
    }

    override public func mouseUp(with event: NSEvent) {
        mouseDragAnchor = nil
        mouseDragTimer?.invalidate()
        mouseDragTimer = nil
        super.mouseUp(with: event)
    }

    override public func mouseDragged(with event: NSEvent) {
        guard !(inputContext?.handleEvent(event) ?? false) && isSelectable else {
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
            selectionManager.setSelectedRange(
                NSRange(
                    location: min(startPosition, endPosition),
                    length: max(startPosition, endPosition) - min(startPosition, endPosition)
                )
            )
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
}
