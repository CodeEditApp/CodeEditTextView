//
//  CursorView.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 8/15/23.
//

import AppKit
import QuartzCore

/// Animates a cursor. Will sync animation with any other cursor views.
///
/// The blink is a Core Animation animation on the view's layer, so it runs on the render server and never wakes
/// the main thread. ``CursorTimer`` starts every cursor's animation from one shared start time, keeping them in step.
open class CursorView: NSView {
    private static let blinkAnimationKey = "blink"

    /// The color of the cursor.
    public var color: NSColor {
        didSet {
            layer?.backgroundColor = color.cgColor
        }
    }

    /// The width of the cursor.
    private let width: CGFloat

    open override var isFlipped: Bool {
        true
    }

    override open func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Create a cursor view.
    /// - Parameters:
    ///   - color: The color of the cursor.
    ///   - width: How wide the cursor should be.
    init(
        color: NSColor = NSColor.labelColor,
        width: CGFloat = 1.0
    ) {
        self.color = color
        self.width = width

        super.init(frame: .zero)

        frame.size.width = width
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
    }

    /// Shows the cursor and blinks it: visible for `blinkDuration`, hidden for `blinkDuration`, repeating.
    /// - Parameters:
    ///   - blinkDuration: How long each visible and hidden phase lasts.
    ///   - startTime: The media time (`CACurrentMediaTime()`) the first visible phase began. Cursors given the same
    ///     start time blink together, whenever each one starts.
    func startBlinking(blinkDuration: TimeInterval, startTime: CFTimeInterval) {
        isHidden = false
        guard blinkDuration > 0, let layer else { return }
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [1.0, 0.0]
        animation.keyTimes = [0.0, 0.5, 1.0]
        animation.calculationMode = .discrete
        animation.duration = blinkDuration * 2
        animation.repeatCount = .infinity
        animation.beginTime = layer.convertTime(startTime, from: nil)
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: Self.blinkAnimationKey)
    }

    /// Stops blinking and shows or hides the cursor.
    func stopBlinking(hidden: Bool) {
        layer?.removeAnimation(forKey: Self.blinkAnimationKey)
        isHidden = hidden
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
