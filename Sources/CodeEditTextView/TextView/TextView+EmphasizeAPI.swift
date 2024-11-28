//
//  TextView+EmphasizeAPI.swift
//  CodeEditTextView
//
//  Created by Tom Ludwig on 05.11.24.
//

import AppKit

/// Emphasizes text ranges within a given text view.
public class EmphasizeAPI {
    // MARK: - Properties

    private var highlightedRanges: [EmphasizedRange] = []
    private var emphasizedRangeIndex: Int?
    private let activeColor: NSColor = NSColor(hex: 0xFFFB00, alpha: 1)
    private let inactiveColor: NSColor = NSColor.lightGray.withAlphaComponent(0.4)

    weak var textView: TextView?

    init(textView: TextView) {
        self.textView = textView
    }

    // MARK: - Structs
    private struct EmphasizedRange {
        var range: NSRange
        var layer: CAShapeLayer
    }

    // MARK: - Public Methods

    /// Emphasises multiple ranges, with one optionally marked as active (highlighted usually in yellow).
    ///
    /// - Parameters:
    ///   - ranges: An array of ranges to highlight.
    ///   - activeIndex: The index of the range to highlight in yellow. Defaults to `nil`.
    ///   - clearPrevious: Removes previous emphasised  ranges. Defaults to `true`.
    public func emphasizeRanges(ranges: [NSRange], activeIndex: Int? = nil, clearPrevious: Bool = true) {
        if clearPrevious {
            removeEmphasizeLayers() // Clear all existing highlights
        }

        ranges.enumerated().forEach { index, range in
            let isActive = (index == activeIndex)
            emphasizeRange(range: range, active: isActive)

            if isActive {
                emphasizedRangeIndex = activeIndex
            }
        }
    }

    /// Emphasises a single range.
    /// - Parameters:
    ///   - range: The text range to highlight.
    ///   - active: Whether the range should be highlighted as active (usually in yellow). Defaults to `false`.
    public func emphasizeRange(range: NSRange, active: Bool = false) {
        guard let shapePath = textView?.layoutManager?.roundedPathForRange(range) else { return }

        let layer = createEmphasizeLayer(shapePath: shapePath, active: active)
        textView?.layer?.insertSublayer(layer, at: 1)

        highlightedRanges.append(EmphasizedRange(range: range, layer: layer))
    }

    /// Removes the highlight for a specific range.
    /// - Parameter range: The range to remove.
    public func removeHighlightForRange(_ range: NSRange) {
        guard let index = highlightedRanges.firstIndex(where: { $0.range == range }) else { return }

        let removedLayer = highlightedRanges[index].layer
        removedLayer.removeFromSuperlayer()

        highlightedRanges.remove(at: index)

        // Adjust the active highlight index
        if let currentIndex = emphasizedRangeIndex {
            if currentIndex == index {
                // TODO: What is the desired behaviour here?
                emphasizedRangeIndex = nil // Reset if the active highlight is removed
            } else if currentIndex > index {
                emphasizedRangeIndex = currentIndex - 1 // Shift if the removed index was before the active index
            }
        }
    }

    /// Highlights the previous emphasised range (usually in yellow).
    ///
    /// - Returns: An optional `NSRange` representing the newly active emphasized range.
    ///            Returns `nil` if there are no prior ranges to highlight.
    @discardableResult
    public func highlightPrevious() -> NSRange? {
        return shiftActiveHighlight(amount: -1)
    }

    /// Highlights the next emphasised range (usually in yellow).
    ///
    /// - Returns: An optional `NSRange` representing the newly active emphasized range.
    ///            Returns `nil` if there are no subsequent ranges to highlight.
    @discardableResult
    public func highlightNext() -> NSRange? {
        return shiftActiveHighlight(amount: 1)
    }

    /// Removes all emphasised ranges.
    public func removeEmphasizeLayers() {
        highlightedRanges.forEach { $0.layer.removeFromSuperlayer() }
        highlightedRanges.removeAll()
        emphasizedRangeIndex = nil
    }

    // MARK: - Private Methods

    private func createEmphasizeLayer(shapePath: NSBezierPath, active: Bool) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.cornerRadius = 3.0
        layer.fillColor = (active ? activeColor : inactiveColor).cgColor
        layer.shadowColor = .black
        layer.shadowOpacity = active ? 0.3 : 0.0
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowRadius = 3.0
        layer.opacity = 1.0

        if #available(macOS 14.0, *) {
            layer.path = shapePath.cgPath
        } else {
            layer.path = shapePath.cgPathFallback
        }

        return layer
    }

    /// Shifts the active highlight to a different emphasized range based on the specified offset.
    ///
    /// - Parameter amount: The offset to shift the active highlight.
    ///                     - A positive value moves to subsequent ranges.
    ///                     - A negative value moves to prior ranges.
    ///
    /// - Returns: An optional `NSRange` representing the newly active highlight, colored in the active color.
    ///            Returns `nil` if no change occurred (e.g., if there are no highlighted ranges).
    private func shiftActiveHighlight(amount: Int) -> NSRange? {
        guard !highlightedRanges.isEmpty else { return nil }

        var currentIndex = emphasizedRangeIndex ?? -1
        currentIndex = (currentIndex + amount + highlightedRanges.count) % highlightedRanges.count

        guard currentIndex < highlightedRanges.count else { return nil }

        // Reset the previously active layer
        if let currentIndex = emphasizedRangeIndex {
            let previousLayer = highlightedRanges[currentIndex].layer
            previousLayer.fillColor = inactiveColor.cgColor
            previousLayer.shadowOpacity = 0.0
        }

        // Set the new active layer
        let newLayer = highlightedRanges[currentIndex].layer
        newLayer.fillColor = activeColor.cgColor
        newLayer.shadowOpacity = 0.3

        applyPopAnimation(to: newLayer)
        emphasizedRangeIndex = currentIndex

        return highlightedRanges[currentIndex].range
    }

    private func applyPopAnimation(to layer: CALayer) {
        let scaleAnimation = CAKeyframeAnimation(keyPath: "transform.scale")
        scaleAnimation.values = [1.0, 1.01, 1.0]
        scaleAnimation.keyTimes = [0, 0.5, 1]
        scaleAnimation.duration = 0.1
        scaleAnimation.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut)
        ]

        layer.add(scaleAnimation, forKey: "popAnimation")
    }
}
