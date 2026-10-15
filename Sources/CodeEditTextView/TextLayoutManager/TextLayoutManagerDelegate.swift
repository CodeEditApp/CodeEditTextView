//
//  TextLayoutManagerDelegate.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 4/10/25.
//

import AppKit

public protocol TextLayoutManagerDelegate: AnyObject {
    func layoutManagerHeightDidUpdate(newHeight: CGFloat)
    func layoutManagerMaxWidthDidChange(newWidth: CGFloat)
    func layoutManagerTypingAttributes() -> [NSAttributedString.Key: Any]
    func textViewportSize() -> CGSize
    func layoutManagerYAdjustment(_ yAdjustment: CGFloat)

    var visibleRect: NSRect { get }

    /// The rect ``TextLayoutManager/layoutLines(in:)`` lays out when no explicit rect is passed.
    ///
    /// Defaults to ``visibleRect``. Delegates backing an `NSScrollView` document view should include any
    /// responsive-scrolling overdraw band (`preparedContentRect`) so a rect-less layout pass doesn't drop the
    /// band's fragments and blank it out on the next draw.
    var preferredLayoutRect: NSRect { get }
}

public extension TextLayoutManagerDelegate {
    var preferredLayoutRect: NSRect { visibleRect }
}
