//
//  EmphasizeAPI.swift
//  CodeEditTextView
//
//  Created by Tom Ludwig on 05.11.24.
//

import AppKit

/// Emphasizes text ranges within a given text view.
public class EmphasizeAPI {
    // MARK: - Properties

    public private(set) var emphasizedRanges: [EmphasizedRange] = []
    public private(set) var emphasizedRangeIndex: Int?
    private let activeColor: NSColor = .findHighlightColor
    private let inactiveColor: NSColor = NSColor.lightGray.withAlphaComponent(0.4)
    private var activeTextLayer: CATextLayer?
    private var originalSelectionColor: NSColor?

    weak var textView: TextView?

    init(textView: TextView) {
        self.textView = textView
    }

    // MARK: - Structs

    public struct EmphasizedRange {
        public var range: NSRange
        var layer: CAShapeLayer
        var textLayer: CATextLayer?
    }

    // MARK: - Public Methods

    /// Emphasises multiple ranges, with one optionally marked as active (highlighted in yellow with black text).
    ///
    /// - Parameters:
    ///   - ranges: An array of ranges to highlight.
    ///   - activeIndex: The index of the range to highlight. Defaults to `nil`.
    ///   - clearPrevious: Removes previous emphasised  ranges. Defaults to `true`.
    public func emphasizeRanges(ranges: [NSRange], activeIndex: Int? = nil, clearPrevious: Bool = true) {
        if clearPrevious {
            removeEmphasizeLayers()
        }

        // Store the current selection background color if not already stored
        if originalSelectionColor == nil {
            originalSelectionColor = textView?.selectionManager.selectionBackgroundColor ?? .selectedTextBackgroundColor
        }
        // Temporarily disable selection highlighting
        textView?.selectionManager.selectionBackgroundColor = .clear

        ranges.enumerated().forEach { index, range in
            let isActive = (index == activeIndex)
            emphasizeRange(range: range, active: isActive)

            if isActive {
                emphasizedRangeIndex = activeIndex
                setTextColorForRange(range, active: true)
            }
        }
    }

    /// Emphasises a single range.
    /// - Parameters:
    ///   - range: The text range to highlight.
    ///   - active: Whether the range should be highlighted as active (black text). Defaults to `false`.
    public func emphasizeRange(range: NSRange, active: Bool = false) {
        guard let shapePath = textView?.layoutManager?.roundedPathForRange(range) else { return }

        let layer = createEmphasizeLayer(shapePath: shapePath, active: active)
        textView?.layer?.insertSublayer(layer, at: 1)

        // Create and add text layer
        if let textLayer = createTextLayer(for: range, active: active) {
            textView?.layer?.addSublayer(textLayer)
            emphasizedRanges.append(EmphasizedRange(range: range, layer: layer, textLayer: textLayer))
        } else {
            emphasizedRanges.append(EmphasizedRange(range: range, layer: layer, textLayer: nil))
        }
    }

    /// Removes the highlight for a specific range.
    /// - Parameter range: The range to remove.
    public func removeHighlightForRange(_ range: NSRange) {
        guard let index = emphasizedRanges.firstIndex(where: { $0.range == range }) else { return }

        let removedLayer = emphasizedRanges[index].layer
        removedLayer.removeFromSuperlayer()

        // Remove text layer
        emphasizedRanges[index].textLayer?.removeFromSuperlayer()

        emphasizedRanges.remove(at: index)

        // Adjust the active highlight index
        if let currentIndex = emphasizedRangeIndex {
            if currentIndex == index {
                emphasizedRangeIndex = nil
            } else if currentIndex > index {
                emphasizedRangeIndex = currentIndex - 1
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
        emphasizedRanges.forEach { range in
            range.layer.removeFromSuperlayer()
            range.textLayer?.removeFromSuperlayer()
        }
        emphasizedRanges.removeAll()
        emphasizedRangeIndex = nil

        // Restore original selection highlighting
        if let originalColor = originalSelectionColor {
            textView?.selectionManager.selectionBackgroundColor = originalColor
        }

        // Force a redraw to ensure colors update
        textView?.needsDisplay = true
    }

    package func updateLayerBackgrounds() {
        emphasizedRanges.enumerated().forEach { (idx, range) in
            let isActive = emphasizedRangeIndex == idx
            range.layer.fillColor = (isActive ? activeColor : inactiveColor).cgColor

            guard let attributedString = range.textLayer?.string as? NSAttributedString else { return }
            let mutableString = NSMutableAttributedString(attributedString: attributedString)
            mutableString.addAttributes(
                [.foregroundColor: isActive ? NSColor.black : getInactiveTextColor()],
                range: NSRange(location: 0, length: range.range.length)
            )
            range.textLayer?.string = mutableString
        }
    }

    // MARK: - Private Methods

    private func createEmphasizeLayer(shapePath: NSBezierPath, active: Bool) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.cornerRadius = 4.0
        layer.fillColor = (active ? activeColor : inactiveColor).cgColor
        layer.shadowColor = .black
        layer.shadowOpacity = active ? 0.5 : 0.0
        layer.shadowOffset = CGSize(width: 0, height: 1.5)
        layer.shadowRadius = 1.5
        layer.opacity = 1.0
        layer.zPosition = active ? 1 : 0

        if #available(macOS 14.0, *) {
            layer.path = shapePath.cgPath
        } else {
            layer.path = shapePath.cgPathFallback
        }

        // Set bounds of the layer; needed for the scale animation
        if let cgPath = layer.path {
            let boundingBox = cgPath.boundingBox
            layer.bounds = boundingBox
            layer.position = CGPoint(x: boundingBox.midX, y: boundingBox.midY)
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
        guard !emphasizedRanges.isEmpty else { return nil }

        var currentIndex = emphasizedRangeIndex ?? -1
        currentIndex = (currentIndex + amount + emphasizedRanges.count) % emphasizedRanges.count

        guard currentIndex < emphasizedRanges.count else { return nil }

        // Reset the previously active layer and text color
        if let currentIndex = emphasizedRangeIndex {
            let previousLayer = emphasizedRanges[currentIndex].layer
            previousLayer.fillColor = inactiveColor.cgColor
            previousLayer.shadowOpacity = 0.0
            setTextColorForRange(emphasizedRanges[currentIndex].range, active: false)
        }

        // Set the new active layer and text color
        let newLayer = emphasizedRanges[currentIndex].layer
        newLayer.fillColor = activeColor.cgColor
        newLayer.shadowOpacity = 0.3
        setTextColorForRange(emphasizedRanges[currentIndex].range, active: true)

        applyPopAnimation(to: newLayer)
        emphasizedRangeIndex = currentIndex

        return emphasizedRanges[currentIndex].range
    }

    private func applyPopAnimation(to layer: CALayer) {
        let scaleAnimation = CAKeyframeAnimation(keyPath: "transform.scale")
        scaleAnimation.values = [1.0, 1.5, 1.0]
        scaleAnimation.keyTimes = [0, 0.3, 1]
        scaleAnimation.duration = 0.2
        scaleAnimation.timingFunctions = [CAMediaTimingFunction(name: .easeOut)]

        layer.add(scaleAnimation, forKey: "popAnimation")
    }

    private func getInactiveTextColor() -> NSColor {
        if textView?.effectiveAppearance.name == .darkAqua {
            return .white
        }
        return .black
    }

    private func createTextLayer(for range: NSRange, active: Bool) -> CATextLayer? {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let shapePath = layoutManager.roundedPathForRange(range),
              let originalString = textView.textStorage?.attributedSubstring(from: range) else {
            return nil
        }

        var bounds = shapePath.bounds
        bounds.origin.y += 1 // Move down by 1 pixel

        // Create text layer
        let textLayer = CATextLayer()
        textLayer.frame = bounds
        textLayer.backgroundColor = NSColor.clear.cgColor
        textLayer.contentsScale = textView.window?.screen?.backingScaleFactor ?? 2.0
        textLayer.allowsFontSubpixelQuantization = true
        textLayer.zPosition = 2

        // Get the font from the attributed string
        if let font = originalString.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
            textLayer.font = font
        } else {
            textLayer.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        }

        updateTextLayer(textLayer, with: originalString, active: active)
        return textLayer
    }

    private func updateTextLayer(_ textLayer: CATextLayer, with originalString: NSAttributedString, active: Bool) {
        let text = NSMutableAttributedString(attributedString: originalString)
        text.addAttribute(
            .foregroundColor,
            value: active ? NSColor.black : getInactiveTextColor(),
            range: NSRange(location: 0, length: text.length)
        )
        textLayer.string = text
    }

    private func setTextColorForRange(_ range: NSRange, active: Bool) {
        guard let index = emphasizedRanges.firstIndex(where: { $0.range == range }),
              let textLayer = emphasizedRanges[index].textLayer,
              let originalString = textView?.textStorage?.attributedSubstring(from: range) else {
            return
        }

        updateTextLayer(textLayer, with: originalString, active: active)
    }
}
