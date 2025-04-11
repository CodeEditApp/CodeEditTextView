//
//  LineFragmentView.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 8/14/23.
//

import AppKit

/// Displays a line fragment.
open class LineFragmentView: NSView {
    public weak var lineFragment: LineFragment?

    open override var isFlipped: Bool {
        true
    }

    open override var isOpaque: Bool {
        false
    }

    open override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Prepare the view for reuse, clears the line fragment reference.
    open override func prepareForReuse() {
        super.prepareForReuse()
        lineFragment = nil
    }

    /// Set a new line fragment for this view, updating view size.
    /// - Parameter newFragment: The new fragment to use.
    open func setLineFragment(_ newFragment: LineFragment) {
        self.lineFragment = newFragment
        self.frame.size = CGSize(width: newFragment.width, height: newFragment.scaledHeight)
    }

    /// Draws the line fragment in the graphics context.
    open override func draw(_ dirtyRect: NSRect) {
        guard let lineFragment, let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        lineFragment.draw(in: context, yPos: 0.0)
    }
}
