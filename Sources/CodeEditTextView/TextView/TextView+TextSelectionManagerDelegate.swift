//
//  TextView+TextSelectionManagerDelegate.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 6/15/24.
//

import AppKit

extension TextView: TextSelectionManagerDelegate {
    /// Dirties every pixel of the view.
    ///
    /// `bounds`, not `frame`: `setNeedsDisplay(_:)` takes a rect in the receiver's own coordinate space. The two
    /// coincide only while `frame.origin` is `.zero` - an `NSClipView` centers a document view smaller than
    /// itself, which gives the frame a non-zero origin and would translate every dirty rect off its target.
    ///
    /// This is the whole-view escape hatch. Selection changes go through the scoped path instead
    /// (``TextSelectionManager/setNeedsDisplayForSelections()``); a full-view invalidation on every keystroke
    /// subsumes every band the layout manager scopes.
    public func setNeedsDisplay() {
        self.setNeedsDisplay(bounds)
    }

    public func estimatedLineHeight() -> CGFloat {
        layoutManager.estimateLineHeight()
    }
}
