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
    public weak var renderer: LineFragmentRenderer?
    private var backgroundAnimation: CABasicAnimation?

    open override var isFlipped: Bool {
        true
    }

    open override var isOpaque: Bool {
        false
    }

    open override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Initialize with random background color animation
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupBackgroundAnimation()
    }

    required public init?(coder: NSCoder) {
        super.init(coder: coder)
        setupBackgroundAnimation()
    }

    /// Setup background animation from random color to clear
    private func setupBackgroundAnimation() {
        // Ensure the view is layer-backed for animation
        self.wantsLayer = true

        // Generate random color
        let randomColor = NSColor(
            red: CGFloat.random(in: 0...1),
            green: CGFloat.random(in: 0...1),
            blue: CGFloat.random(in: 0...1),
            alpha: 0.3 // Start with some transparency
        )

        // Set initial background color
        self.layer?.backgroundColor = randomColor.cgColor

        // Create animation from random color to clear
        let animation = CABasicAnimation(keyPath: "backgroundColor")
        animation.fromValue = randomColor.cgColor
        animation.toValue = NSColor.clear.cgColor
        animation.duration = 1.0
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false

        // Apply animation
        self.layer?.add(animation, forKey: "backgroundColorAnimation")

        // Set final state
        DispatchQueue.main.asyncAfter(deadline: .now() + animation.duration) {
            self.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    /// Prepare the view for reuse, clears the line fragment reference and restarts animation.
    open override func prepareForReuse() {
        super.prepareForReuse()
        lineFragment = nil

        // Restart the background animation
        setupBackgroundAnimation()
    }

    /// Set a new line fragment for this view, updating view size.
    /// - Parameter newFragment: The new fragment to use.
    open func setLineFragment(_ newFragment: LineFragment, renderer: LineFragmentRenderer) {
        self.lineFragment = newFragment
        self.renderer = renderer
        self.frame.size = CGSize(width: newFragment.width, height: newFragment.scaledHeight)
    }

    /// Draws the line fragment in the graphics context.
    open override func draw(_ dirtyRect: NSRect) {
        guard let lineFragment, let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        renderer?.draw(lineFragment: lineFragment, in: context, yPos: 0.0)
    }
}
