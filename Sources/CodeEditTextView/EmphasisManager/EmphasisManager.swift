//
//  EmphasisManager.swift
//  CodeEditTextView
//
//  Created by Tom Ludwig on 05.11.24.
//

import AppKit

/// Defines the style of emphasis to apply to text ranges
public enum EmphasisStyle: Equatable {
    /// Standard emphasis with background color
    case standard
    /// Underline emphasis with a line color
    case underline(color: NSColor)
    /// Outline emphasis with a border color
    case outline(color: NSColor)

    public static func == (lhs: EmphasisStyle, rhs: EmphasisStyle) -> Bool {
        switch (lhs, rhs) {
        case (.standard, .standard):
            return true
        case (.underline(let lhsColor), .underline(let rhsColor)):
            return lhsColor == rhsColor
        case (.outline(let lhsColor), .outline(let rhsColor)):
            return lhsColor == rhsColor
        default:
            return false
        }
    }
}

/// Represents a single emphasis with its properties
public struct Emphasis {
    public let range: NSRange
    public let style: EmphasisStyle
    public let flash: Bool
    public let inactive: Bool
    public let select: Bool

    public init(
        range: NSRange,
        style: EmphasisStyle = .standard,
        flash: Bool = false,
        inactive: Bool = false,
        select: Bool = false
    ) {
        self.range = range
        self.style = style
        self.flash = flash
        self.inactive = inactive
        self.select = select
    }
}

/// Manages text emphases within a text view, supporting multiple styles and groups.
public final class EmphasisManager {
    /// Internal representation of a emphasis layer with its associated text layer
    private struct EmphasisLayer {
        let emphasis: Emphasis
        let layer: CAShapeLayer
        let textLayer: CATextLayer?
    }

    private var emphasisGroups: [String: [EmphasisLayer]] = [:]
    private let activeColor: NSColor = .findHighlightColor
    private let inactiveColor: NSColor = NSColor.lightGray.withAlphaComponent(0.4)
    private var originalSelectionColor: NSColor?

    weak var textView: TextView?

    init(textView: TextView) {
        self.textView = textView
    }

    /// Adds a single emphasis to the specified group.
    /// - Parameters:
    ///   - emphasis: The emphasis to add
    ///   - id: The group identifier
    public func addEmphasis(_ emphasis: Emphasis, for id: String) {
        addEmphases([emphasis], for: id)
    }

    /// Adds multiple emphases to the specified group.
    /// - Parameters:
    ///   - emphases: The emphases to add
    ///   - id: The group identifier
    public func addEmphases(_ emphases: [Emphasis], for id: String) {
        // Store the current selection background color if not already stored
        if originalSelectionColor == nil {
            originalSelectionColor = textView?.selectionManager.selectionBackgroundColor ?? .selectedTextBackgroundColor
        }

        let layers = emphases.map { createEmphasisLayer(for: $0) }
        emphasisGroups[id] = layers

        // Handle selections
        handleSelections(for: emphases)

        // Handle flash animations
        for (index, emphasis) in emphases.enumerated() where emphasis.flash {
            let layer = layers[index]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.applyFadeOutAnimation(to: layer.layer, textLayer: layer.textLayer)
                // Remove the emphasis from the group
                if var emphases = self.emphasisGroups[id] {
                    emphases.remove(at: index)
                    if emphases.isEmpty {
                        self.emphasisGroups.removeValue(forKey: id)
                    } else {
                        self.emphasisGroups[id] = emphases
                    }
                }
            }
        }
    }

    /// Replaces all emphases in the specified group.
    /// - Parameters:
    ///   - emphases: The new emphases
    ///   - id: The group identifier
    public func replaceEmphases(_ emphases: [Emphasis], for id: String) {
        removeEmphases(for: id)
        addEmphases(emphases, for: id)
    }

    /// Updates the emphases for a group by transforming the existing array.
    /// - Parameters:
    ///   - id: The group identifier
    ///   - transform: The transformation to apply to the existing emphases
    public func updateEmphases(for id: String, _ transform: ([Emphasis]) -> [Emphasis]) {
        guard let existingLayers = emphasisGroups[id] else { return }
        let existingEmphases = existingLayers.map { $0.emphasis }
        let newEmphases = transform(existingEmphases)
        replaceEmphases(newEmphases, for: id)
    }

    /// Removes all emphases for the given group.
    /// - Parameter id: The group identifier
    public func removeEmphases(for id: String) {
        emphasisGroups[id]?.forEach { layer in
            layer.layer.removeAllAnimations()
            layer.layer.removeFromSuperlayer()
            layer.textLayer?.removeAllAnimations()
            layer.textLayer?.removeFromSuperlayer()
        }
        emphasisGroups[id] = nil
    }

    /// Removes all emphases for all groups.
    public func removeAllEmphases() {
        emphasisGroups.keys.forEach { removeEmphases(for: $0) }
        emphasisGroups.removeAll()

        // Restore original selection emphasising
        if let originalColor = originalSelectionColor {
            textView?.selectionManager.selectionBackgroundColor = originalColor
        }
        originalSelectionColor = nil
    }

    /// Gets all emphases for a given group.
    /// - Parameter id: The group identifier
    /// - Returns: Array of emphases in the group
    public func getEmphases(for id: String) -> [Emphasis] {
        emphasisGroups[id]?.map { $0.emphasis } ?? []
    }

    /// Updates the positions and bounds of all emphasis layers to match the current text layout.
    public func updateLayerBackgrounds() {
        for (_, layers) in emphasisGroups {
            for layer in layers {
                if let shapePath = textView?.layoutManager?.roundedPathForRange(layer.emphasis.range) {
                    if #available(macOS 14.0, *) {
                        layer.layer.path = shapePath.cgPath
                    } else {
                        layer.layer.path = shapePath.cgPathFallback
                    }

                    // Update bounds and position
                    if let cgPath = layer.layer.path {
                        let boundingBox = cgPath.boundingBox
                        layer.layer.bounds = boundingBox
                        layer.layer.position = CGPoint(x: boundingBox.midX, y: boundingBox.midY)
                    }

                    // Update text layer if it exists
                    if let textLayer = layer.textLayer {
                        var bounds = shapePath.bounds
                        bounds.origin.y += 1 // Move down by 1 pixel
                        textLayer.frame = bounds
                    }
                }
            }
        }
    }

    private func createEmphasisLayer(for emphasis: Emphasis) -> EmphasisLayer {
        guard let shapePath = textView?.layoutManager?.roundedPathForRange(emphasis.range) else {
            return EmphasisLayer(emphasis: emphasis, layer: CAShapeLayer(), textLayer: nil)
        }

        let layer = createShapeLayer(shapePath: shapePath, emphasis: emphasis)
        textView?.layer?.insertSublayer(layer, at: 1)

        let textLayer = createTextLayer(for: emphasis)
        if let textLayer = textLayer {
            textView?.layer?.addSublayer(textLayer)
        }

        if emphasis.inactive == false && emphasis.style == .standard {
            applyPopAnimation(to: layer)
        }

        return EmphasisLayer(emphasis: emphasis, layer: layer, textLayer: textLayer)
    }

    private func createShapeLayer(shapePath: NSBezierPath, emphasis: Emphasis) -> CAShapeLayer {
        let layer = CAShapeLayer()

        switch emphasis.style {
        case .standard:
            layer.cornerRadius = 4.0
            layer.fillColor = (emphasis.inactive ? inactiveColor : activeColor).cgColor
            layer.shadowColor = .black
            layer.shadowOpacity = emphasis.inactive ? 0.0 : 0.5
            layer.shadowOffset = CGSize(width: 0, height: 1.5)
            layer.shadowRadius = 1.5
            layer.opacity = 1.0
            layer.zPosition = emphasis.inactive ? 0 : 1
        case .underline(let color):
            layer.lineWidth = 1.0
            layer.lineCap = .round
            layer.strokeColor = color.cgColor
            layer.fillColor = nil
            layer.opacity = emphasis.flash ? 0.0 : 1.0
            layer.zPosition = 1
        case .outline(let color):
            layer.cornerRadius = 2.5
            layer.borderColor = color.cgColor
            layer.borderWidth = 0.5
            layer.fillColor = nil
            layer.opacity = emphasis.flash ? 0.0 : 1.0
            layer.zPosition = 1
        }

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

    private func createTextLayer(for emphasis: Emphasis) -> CATextLayer? {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let shapePath = layoutManager.roundedPathForRange(emphasis.range),
              let originalString = textView.textStorage?.attributedSubstring(from: emphasis.range) else {
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

        updateTextLayer(textLayer, with: originalString, emphasis: emphasis)
        return textLayer
    }

    private func updateTextLayer(
        _ textLayer: CATextLayer,
        with originalString: NSAttributedString,
        emphasis: Emphasis
    ) {
        let text = NSMutableAttributedString(attributedString: originalString)
        text.addAttribute(
            .foregroundColor,
            value: emphasis.inactive ? getInactiveTextColor() : NSColor.black,
            range: NSRange(location: 0, length: text.length)
        )
        textLayer.string = text
    }

    private func getInactiveTextColor() -> NSColor {
        if textView?.effectiveAppearance.name == .darkAqua {
            return .white
        }
        return .black
    }

    private func applyPopAnimation(to layer: CALayer) {
        let scaleAnimation = CAKeyframeAnimation(keyPath: "transform.scale")
        scaleAnimation.values = [1.0, 1.25, 1.0]
        scaleAnimation.keyTimes = [0, 0.3, 1]
        scaleAnimation.duration = 0.1
        scaleAnimation.timingFunctions = [CAMediaTimingFunction(name: .easeOut)]

        layer.add(scaleAnimation, forKey: "popAnimation")
    }

    private func applyFadeOutAnimation(to layer: CALayer, textLayer: CATextLayer?) {
        let fadeAnimation = CABasicAnimation(keyPath: "opacity")
        fadeAnimation.fromValue = 1.0
        fadeAnimation.toValue = 0.0
        fadeAnimation.duration = 0.1
        fadeAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fadeAnimation.fillMode = .forwards
        fadeAnimation.isRemovedOnCompletion = false

        layer.add(fadeAnimation, forKey: "fadeOutAnimation")

        if let textLayer = textLayer {
            if let textFadeAnimation = fadeAnimation.copy() as? CABasicAnimation {
                textLayer.add(textFadeAnimation, forKey: "fadeOutAnimation")
            }
        }

        // Remove both layers after animation completes
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeAnimation.duration) {
            layer.removeFromSuperlayer()
            textLayer?.removeFromSuperlayer()
        }
    }

    /// Handles selection of text ranges for emphases where select is true
    private func handleSelections(for emphases: [Emphasis]) {
        let selectableRanges = emphases.filter(\.select).map(\.range)
        guard let textView, !selectableRanges.isEmpty else { return }

        textView.selectionManager.setSelectedRanges(selectableRanges)
        textView.scrollSelectionToVisible()
        textView.needsDisplay = true
    }
}
