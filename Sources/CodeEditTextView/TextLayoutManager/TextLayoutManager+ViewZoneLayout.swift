//
//  TextLayoutManager+ViewZoneLayout.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 8/10/26.
//

import AppKit

/// View-zone placement helpers for the layout pass. The pass itself (`layoutVisibleZones`) lives with the rest of
/// the layout pipeline in `TextLayoutManager+Layout.swift`.
extension TextLayoutManager {
    /// Returns the index of the first zone whose whitespace band ends at or below `minY`.
    ///
    /// Band positions are non-decreasing in the `(afterLineNumber, ordinal)` sort order, keeping the predicate
    /// binary-searchable. The band-end used for the probe is the end of the *entire* stack at the probe's gap
    /// line, so every zone sharing a gap line yields the same value and the result is always the first zone of
    /// its gap line - which `layoutVisibleZones` requires to stack same-line zones correctly.
    func firstZoneIndex(reaching minY: CGFloat, in zones: [ViewZone]) -> Int {
        guard minY > 0 else { return 0 }
        var low = 0
        var high = zones.count
        while low < high {
            let mid = (low + high) / 2
            let gapLine = zones[mid].afterLineNumber
            let lineBottom: CGFloat
            if gapLine < 0 {
                lineBottom = 0
            } else if let linePosition = lineStorage.getLine(atIndex: gapLine) {
                lineBottom = linePosition.yPos + linePosition.height
            } else {
                lineBottom = lineStorage.height
            }
            // Whitespace before line `gapLine + 1` covers all zones at or before this gap line.
            let bandMaxY = lineBottom + viewZones.whitespaceHeightBeforeLine(gapLine + 1)
            if bandMaxY <= minY {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    /// Positions a view zone's view at the given document y position.
    /// - Parameters:
    ///   - zone: The view zone to layout.
    ///   - yPos: The y position in document coordinates where the zone should be placed.
    func layoutViewZone(_ zone: ViewZone, at yPos: CGFloat) {
        guard let zoneView = zone.view else { return }
        zoneView.translatesAutoresizingMaskIntoConstraints = true
        let width = (delegate?.textViewportSize().width ?? layoutView?.bounds.width) ?? 0
        zoneView.frame = CGRect(x: 0, y: yPos, width: width, height: zone.heightInPoints)
        if zoneView.superview !== layoutView {
            layoutView?.addSubview(zoneView, positioned: .above, relativeTo: nil)
        }
    }
}
