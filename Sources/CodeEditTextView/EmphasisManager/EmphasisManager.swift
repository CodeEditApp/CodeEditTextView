//
//  EmphasisManager.swift
//  CodeEditTextView
//
//  Created by Tom Ludwig on 05.11.24.
//

import AppKit

/// Manages text emphases within a text view, supporting multiple styles and groups.
///
/// Text emphasis draws attention to a range of text, indicating importance.
/// This object may be used in a code editor to emphasize search results, or indicate 
/// bracket pairs, for instance.
///
/// This object is designed to allow for easy grouping of emphasis types. An outside 
/// object is responsible for managing what emphases are visible. Because it's very 
/// likely that more than one type of emphasis may occur on the document at the same
/// time, grouping allows each emphasis to be managed separately from the others by
/// each outside object without knowledge of the other's state.
public final class EmphasisManager {
    /// Internal representation of a emphasis layer with its associated text layer
    private struct EmphasisLayer: Equatable {
        let emphasis: Emphasis
        let layer: CAShapeLayer
        /// Created once the emphasized text has been laid out; see ``createEmphasisLayer(for:)``.
        var textLayer: CATextLayer?
        /// The layout revision the layer geometry was last computed for; see ``updateLayerBackgrounds()``.
        var revision: UInt64 = .max

        /// The shape layer identifies the entry: it never changes, while the text layer may be added later.
        static func == (lhs: EmphasisLayer, rhs: EmphasisLayer) -> Bool {
            lhs.emphasis == rhs.emphasis && lhs.layer === rhs.layer
        }

        func removeLayers() {
            layer.removeAllAnimations()
            layer.removeFromSuperlayer()
            textLayer?.removeAllAnimations()
            textLayer?.removeFromSuperlayer()
        }
    }

    private var emphasisGroups: [String: [EmphasisLayer]] = [:] {
        didSet {
            // New layers need geometry; removed ones may have covered the text range already updated.
            coveredTextRange = nil
        }
    }
    /// The layout revision and text range ``updateLayerBackgrounds()`` last brought up to date. Nil when emphases
    /// changed since.
    private var coveredRevision: UInt64 = .max
    private var coveredTextRange: NSRange?
    private let activeColor: NSColor = .findHighlightColor
    private let inactiveColor: NSColor = NSColor.lightGray.withAlphaComponent(0.4)
    private var originalSelectionColor: NSColor?

    weak var textView: TextView?

    init(textView: TextView) {
        self.textView = textView
    }

    // MARK: - Add, Update, Remove

    /// Adds a single emphasis to the specified group.
    /// - Parameters:
    ///   - emphasis: The emphasis to add
    ///   - id: A group identifier
    public func addEmphasis(_ emphasis: Emphasis, for id: String) {
        addEmphases([emphasis], for: id)
    }

    /// Adds multiple emphases to the specified group.
    /// - Parameters:
    ///   - emphases: The emphases to add
    ///   - id: The group identifier
    public func addEmphases(_ emphases: [Emphasis], for id: String) {
        // Empty and out-of-bounds ranges (e.g. computed before an edit landed) cannot be emphasized;
        // using them against the text storage would raise NSRangeException.
        let storageLength = textView?.textStorage?.length ?? 0
        let validEmphases = emphases.filter { emphasis in
            emphasis.range.location >= 0 && emphasis.range.length > 0 && emphasis.range.upperBound <= storageLength
        }
        guard !validEmphases.isEmpty else { return }

        // Store the current selection background color if not already stored
        if originalSelectionColor == nil {
            originalSelectionColor = textView?.selectionManager.selectionBackgroundColor ?? .selectedTextBackgroundColor
        }

        let layers = validEmphases.map { createEmphasisLayer(for: $0) }
        emphasisGroups[id, default: []].append(contentsOf: layers)
        // Handle selections
        handleSelections(for: validEmphases)

        // Handle flash animations
        for flashingLayer in emphasisGroups[id, default: []].filter({ $0.emphasis.flash }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                self.applyFadeOutAnimation(to: flashingLayer.layer, textLayer: flashingLayer.textLayer) {
                    // Remove the emphasis from the group if it still exists
                    guard let emphasisIdx = self.emphasisGroups[id, default: []].firstIndex(
                        where: { $0 == flashingLayer }
                    ) else {
                        return
                    }

                    self.emphasisGroups[id, default: []][emphasisIdx].removeLayers()
                    self.emphasisGroups[id, default: []].remove(at: emphasisIdx)

                    if self.emphasisGroups[id, default: []].isEmpty {
                        self.emphasisGroups.removeValue(forKey: id)
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
        let existingEmphases = emphasisGroups[id, default: []].map { $0.emphasis }
        let newEmphases = transform(existingEmphases)
        replaceEmphases(newEmphases, for: id)
    }

    /// Removes all emphases for the given group.
    /// - Parameter id: The group identifier
    public func removeEmphases(for id: String) {
        // Early return when there's nothing to remove: this is called from frame-change observers that
        // fire on every frame of animated resizes, and the forced synchronous layer layout below is only
        // needed when layers were actually removed.
        guard let emphases = emphasisGroups[id] else { return }
        emphases.forEach { emphasis in
            emphasis.removeLayers()
        }
        emphasisGroups[id] = nil

        textView?.layer?.layoutIfNeeded()
    }

    /// Removes all emphases for all groups.
    public func removeAllEmphases() {
        emphasisGroups.keys.forEach { removeEmphases(for: $0) }
        emphasisGroups.removeAll()

        // Restore original selection emphasizing
        if let originalColor = originalSelectionColor {
            textView?.selectionManager.selectionBackgroundColor = originalColor
        }
        originalSelectionColor = nil
    }

    /// Gets all emphases for a given group.
    /// - Parameter id: The group identifier
    /// - Returns: Array of emphases in the group
    public func getEmphases(for id: String) -> [Emphasis] {
        emphasisGroups[id, default: []].map(\.emphasis)
    }

    // MARK: - Drawing Layers

    /// Updates the positions and bounds of the emphasis layers in view to match the current text layout.
    ///
    /// The text view calls this on every draw, so it returns immediately unless the layout changed (the layout
    /// manager's `layoutRevision`), emphases were added or removed, or text came into view that was not covered
    /// before. It then recomputes geometry only for emphases overlapping the visible text (plus the layout padding),
    /// and hides the layers left with geometry from an older layout: their text is off screen, but after an edit
    /// their stale position might not be. Recomputing every emphasis on every draw cost 1.1 ms per draw with 1,000
    /// find matches and 8.6 ms with 10,000.
    public func updateLayerBackgrounds() {
        guard let textView, let layoutManager = textView.layoutManager, !emphasisGroups.isEmpty else { return }
        let revision = layoutManager.layoutRevision
        let visibleRange = textView.visibleTextRange(verticalPadding: layoutManager.verticalLayoutPadding)
            ?? NSRange(location: 0, length: textView.textStorage?.length ?? 0)
        if revision == coveredRevision, let coveredTextRange,
           NSIntersectionRange(coveredTextRange, visibleRange) == visibleRange {
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let storageLength = textView.textStorage?.length ?? 0
        for id in emphasisGroups.keys {
            guard var layers = emphasisGroups[id] else { continue }
            var changed = false
            for index in layers.indices where layers[index].revision != revision {
                let range = layers[index].emphasis.range
                let inView = range.location <= visibleRange.max && range.max >= visibleRange.location
                if inView {
                    updateGeometry(of: &layers[index], storageLength: storageLength)
                    layers[index].revision = revision
                    changed = true
                } else if !layers[index].layer.isHidden {
                    // Off screen and about to go stale: hide until it comes into view and is updated.
                    layers[index].layer.isHidden = true
                    layers[index].textLayer?.isHidden = true
                }
            }
            if changed {
                // Resets `coveredTextRange` through `didSet`; it is set again below.
                emphasisGroups[id] = layers
            }
        }
        CATransaction.commit()

        if revision == coveredRevision, let coveredTextRange {
            self.coveredTextRange = NSUnionRange(coveredTextRange, visibleRange)
        } else {
            coveredTextRange = visibleRange
        }
        coveredRevision = revision
    }

    /// Recomputes one layer's geometry for the current layout and shows it, or hides it when its range no longer
    /// exists in the document (or cannot be laid out yet).
    private func updateGeometry(of emphasis: inout EmphasisLayer, storageLength: Int) {
        let range = emphasis.emphasis.range
        // An edit may have removed the emphasized text. Hide the layers rather than let
        // `roundedPathForRange`'s zero-length clamp reposition them to a caret-sized ghost rect.
        let isStale = range.length == 0 || range.upperBound > storageLength
        guard !isStale, let shapePath = makeShapePath(forStyle: emphasis.emphasis.style, range: range) else {
            emphasis.layer.isHidden = true
            emphasis.textLayer?.isHidden = true
            return
        }
        if emphasis.textLayer == nil, let textLayer = createTextLayer(for: emphasis.emphasis) {
            textView?.layer?.addSublayer(textLayer)
            emphasis.textLayer = textLayer
        }
        emphasis.layer.isHidden = false
        emphasis.textLayer?.isHidden = false
        if #available(macOS 14.0, *) {
            emphasis.layer.path = shapePath.cgPath
        } else {
            emphasis.layer.path = shapePath.cgPathFallback
        }

        // Update bounds and position
        if let cgPath = emphasis.layer.path {
            let boundingBox = cgPath.boundingBox
            emphasis.layer.bounds = boundingBox
            emphasis.layer.position = CGPoint(x: boundingBox.midX, y: boundingBox.midY)
        }

        // Update text layer if it exists
        if let textLayer = emphasis.textLayer {
            // The overlay spans the glyph bounding path, not the style's shape path - an
            // underline stroke path has zero height.
            let overlayBounds: CGRect?
            if case .underline = emphasis.emphasis.style {
                overlayBounds = textView?.layoutManager.roundedPathForRange(range)?.bounds
            } else {
                overlayBounds = shapePath.bounds
            }
            if var bounds = overlayBounds {
                bounds.origin.y += 1 // Move down by 1 pixel
                textLayer.frame = bounds
            }
        }
    }

    /// Creates and inserts the layers for an emphasis.
    ///
    /// Text that has not been laid out yet (off screen, in a large document) has no geometry. Its shape layer is
    /// still inserted, hidden, and ``updateLayerBackgrounds()`` gives it geometry - and creates its text layer - once
    /// it comes into view. (Without the layer in the tree, a find match outside the initial viewport never showed.)
    private func createEmphasisLayer(for emphasis: Emphasis) -> EmphasisLayer {
        let shapePath = makeShapePath(forStyle: emphasis.style, range: emphasis.range)
        let layer = createShapeLayer(shapePath: shapePath, emphasis: emphasis)
        textView?.layer?.insertSublayer(layer, at: 1)

        let textLayer = shapePath == nil ? nil : createTextLayer(for: emphasis)
        if let textLayer = textLayer {
            textView?.layer?.addSublayer(textLayer)
        }

        if emphasis.inactive == false && emphasis.style == .standard {
            applyPopAnimation(to: layer)
        }

        return EmphasisLayer(emphasis: emphasis, layer: layer, textLayer: textLayer)
    }

    private func makeShapePath(forStyle emphasisStyle: EmphasisStyle, range: NSRange) -> NSBezierPath? {
        switch emphasisStyle {
        case .standard, .outline:
            return textView?.layoutManager.roundedPathForRange(range, cornerRadius: emphasisStyle.shapeRadius)
        case .underline:
            guard let layoutManager = textView?.layoutManager else {
                return nil
            }
            let lineHeight = layoutManager.estimateLineHeight()
            let lineBottomPadding = (lineHeight - (lineHeight / layoutManager.lineHeightMultiplier)) / 4
            let path = NSBezierPath()
            for rect in layoutManager.rectsFor(range: range) {
                path.move(to: NSPoint(x: rect.minX, y: rect.maxY - lineBottomPadding))
                path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - lineBottomPadding))
            }
            return path
        }
    }

    private func createShapeLayer(shapePath: NSBezierPath?, emphasis: Emphasis) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.isHidden = shapePath == nil

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
            layer.opacity = 1.0
            layer.zPosition = 1
        case let .outline(color, shouldFill):
            layer.cornerRadius = 2.5
            layer.borderColor = color.cgColor
            layer.borderWidth = 0.5
            layer.fillColor = shouldFill ? color.cgColor : nil
            layer.opacity = 1.0
            layer.zPosition = 1
        }

        guard let shapePath else { return layer }
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
        // `roundedPathForRange` clamps out-of-bounds ranges and returns a caret-rect path for zero-length
        // results, so it cannot serve as the bounds check here.
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textStorage = textView.textStorage,
              emphasis.range.location >= 0,
              emphasis.range.length > 0,
              emphasis.range.upperBound <= textStorage.length,
              let shapePath = layoutManager.roundedPathForRange(emphasis.range) else {
            return nil
        }
        let originalString = textStorage.attributedSubstring(from: emphasis.range)

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

    // MARK: - Animations

    private func applyPopAnimation(to layer: CALayer) {
        let scaleAnimation = CAKeyframeAnimation(keyPath: "transform.scale")
        scaleAnimation.values = [1.0, 1.25, 1.0]
        scaleAnimation.keyTimes = [0, 0.3, 1]
        scaleAnimation.duration = 0.1
        scaleAnimation.timingFunctions = [CAMediaTimingFunction(name: .easeOut)]

        layer.add(scaleAnimation, forKey: "popAnimation")
    }

    private func applyFadeOutAnimation(to layer: CALayer, textLayer: CATextLayer?, completion: @escaping () -> Void) {
        let fadeAnimation = CABasicAnimation(keyPath: "opacity")
        fadeAnimation.fromValue = 1.0
        fadeAnimation.toValue = 0.0
        fadeAnimation.duration = 0.1
        fadeAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fadeAnimation.fillMode = .forwards
        fadeAnimation.isRemovedOnCompletion = false

        layer.add(fadeAnimation, forKey: "fadeOutAnimation")

        if let textLayer = textLayer, let textFadeAnimation = fadeAnimation.copy() as? CABasicAnimation {
            textLayer.add(textFadeAnimation, forKey: "fadeOutAnimation")
            textLayer.add(textFadeAnimation, forKey: "fadeOutAnimation")
        }

        // Remove both layers after animation completes
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeAnimation.duration) {
            layer.removeFromSuperlayer()
            textLayer?.removeFromSuperlayer()
            completion()
        }
    }

    /// Handles selection of text ranges for emphases where select is true
    private func handleSelections(for emphases: [Emphasis]) {
        let selectableRanges = emphases.filter(\.selectInDocument).map(\.range)
        guard let textView, !selectableRanges.isEmpty else { return }

        textView.selectionManager.setSelectedRanges(selectableRanges)
        textView.scrollSelectionToVisible()
        textView.needsDisplay = true
    }
}
