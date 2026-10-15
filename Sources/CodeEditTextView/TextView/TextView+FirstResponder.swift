//
//  TextView+FirstResponder.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 6/15/24.
//

import AppKit

extension TextView {
    /// Posted, with the text view as its object, when the text view becomes or stops being the first responder.
    /// Selections are drawn in other colors while it isn't; a view that draws its selections elsewhere (a minimap)
    /// redraws them.
    public static let firstResponderDidChangeNotification = Notification.Name(
        "com.CodeEdit.TextView.FirstResponderDidChange"
    )

    open override func becomeFirstResponder() -> Bool {
        isFirstResponder = true
        selectionManager.cursorTimer.resetTimer()
        needsDisplay = true
        NotificationCenter.default.post(name: Self.firstResponderDidChangeNotification, object: self)
        return super.becomeFirstResponder()
    }

    open override func resignFirstResponder() -> Bool {
        isFirstResponder = false
        selectionManager.removeCursors()
        needsDisplay = true
        NotificationCenter.default.post(name: Self.firstResponderDidChangeNotification, object: self)
        return super.resignFirstResponder()
    }

    open override var canBecomeKeyView: Bool {
        super.canBecomeKeyView && acceptsFirstResponder && !isHiddenOrHasHiddenAncestor
    }

    /// Sent to the window's first responder when `NSWindow.makeKey()` occurs.
    @objc private func becomeKeyWindow() {
        _ = becomeFirstResponder()
    }

    /// Sent to the window's first responder when `NSWindow.resignKey()` occurs.
    @objc private func resignKeyWindow() {
        _ = resignFirstResponder()
    }

    open override var needsPanelToBecomeKey: Bool {
        isSelectable || isEditable
    }

    open override var acceptsFirstResponder: Bool {
        isSelectable
    }

    open override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    open override func resetCursorRects() {
        super.resetCursorRects()
        if isSelectable {
            addCursorRect(
                visibleRect,
                cursor: isOptionPressed ? .crosshair : .iBeam
            )
        }
    }
}
