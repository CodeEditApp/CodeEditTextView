//
//  CursorTimer.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 1/16/24.
//

import Foundation
import AppKit
import QuartzCore

/// Blinks registered cursors in unison.
///
/// Each cursor blinks with its own Core Animation animation (see ``CursorView``), so no timer fires on the main
/// thread. This type records the blink duration and the time the current blink began, and starts every cursor
/// registered with it from that same time.
class CursorTimer {
    /// # Properties

    /// The duration of each visible and hidden phase, or `nil` when cursors are not blinking.
    private var blinkDuration: TimeInterval?
    /// The media time the current blink began. Every cursor's animation starts here, so all cursors blink together.
    private var blinkStartTime: CFTimeInterval = 0
    /// Maps to all cursor views, uses weak memory to not cause a strong reference cycle.
    private var cursors: NSHashTable<CursorView> = .init(options: .weakMemory)

    // MARK: - Methods

    /// Resets the cursor blink: cursors become visible immediately and start a new blink cycle.
    /// - Parameter newBlinkDuration: The duration to blink, leave as nil to never blink. When nil, cursors are hidden.
    func resetTimer(newBlinkDuration: TimeInterval? = 0.5) {
        blinkDuration = newBlinkDuration
        blinkStartTime = CACurrentMediaTime()
        for cursor in cursors.allObjects {
            if let newBlinkDuration {
                cursor.startBlinking(blinkDuration: newBlinkDuration, startTime: blinkStartTime)
            } else {
                cursor.stopBlinking(hidden: true)
            }
        }
    }

    /// Hides all cursors, stops blinking, and forgets every registered cursor.
    func stopTimer() {
        blinkDuration = nil
        for cursor in cursors.allObjects {
            cursor.stopBlinking(hidden: true)
        }
        cursors.removeAllObjects()
    }

    /// Register a new cursor view with the timer.
    /// - Parameter newCursor: The cursor to blink. If a blink is running, the cursor joins it in step with the other
    ///   cursors.
    func register(_ newCursor: CursorView) {
        cursors.add(newCursor)
        if let blinkDuration {
            newCursor.startBlinking(blinkDuration: blinkDuration, startTime: blinkStartTime)
        }
    }
}
