//
//  PixelAligned.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 9/10/23.
//

import Foundation
import CoreGraphics

public extension NSRect {
    /// Creates a rect pixel-aligned on all edges.
    var pixelAligned: NSRect {
        NSIntegralRectWithOptions(self, .alignAllEdgesNearest)
    }
}

public extension NSPoint {
    /// Creates a point that's pixel-aligned.
    var pixelAligned: NSPoint {
        NSIntegralRectWithOptions(NSRect(x: self.x, y: self.y, width: 0, height: 0), .alignAllEdgesNearest).origin
    }
}

extension CGContext {
    /// `rect` with every edge moved to the nearest device pixel boundary, in user space.
    ///
    /// For fills. Core Graphics antialiases a fill edge that falls between pixels differently depending on the clip:
    /// an edge a hundredth of a pixel past a boundary can come out empty under one clip and fully covered under
    /// another. Redraws are clipped to whatever changed, so a fill redrawn under a different clip than its neighbors
    /// would leave a notch along its edge. On a pixel boundary every clip agrees.
    func deviceAligned(_ rect: CGRect) -> CGRect {
        let device = convertToDeviceSpace(rect)
        let minX = device.minX.rounded()
        let minY = device.minY.rounded()
        let maxX = device.maxX.rounded()
        let maxY = device.maxY.rounded()
        return convertToUserSpace(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
    }
}
