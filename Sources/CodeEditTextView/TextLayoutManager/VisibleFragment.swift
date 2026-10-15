//
//  VisibleFragment.swift
//  CodeEditTextView
//
//  Created by Abe Malla on 4/19/26.
//

import AppKit

/// A `LineFragment` that has been laid out and is currently drawn into the text view's graphics context.
///
/// `TextLayoutManager` stores these in a flat, y-ordered list (`visibleFragments`) which `TextView.draw(_:)` walks to
/// rasterize visible text. Replaces the per-fragment `NSView` we used to `addSubview` for every visible fragment -
/// those `NSView`s triggered AppKit hit-testing, constraint/dirty-rect propagation, and CA transaction flushes on every
/// scroll frame. Drawing fragments directly into the text view's layer is O(visible-fragments) with no view-tree churn.
public struct VisibleFragment {
    /// The fragment being drawn. Strong reference - the fragment is owned by the parent `TextLine`, which the layout
    /// manager keeps alive via `lineStorage`, so this reference can't dangle.
    public let fragment: LineFragment

    /// The x origin of the fragment in the text view's coordinate space (typically `edgeInsets.left`).
    public let xPos: CGFloat

    /// The y origin of the fragment in the text view's coordinate space (`TextView` is flipped, so this is document y).
    public let yPos: CGFloat

    /// Width of the fragment as laid out.
    public let width: CGFloat

    /// Height of the fragment's drawing rect (`scaledHeight`, not just text height).
    public let height: CGFloat

    /// The top of the fragment's pixels: its rect's top, raised by any ink reaching above it
    /// (``LineFragment/inkOverflowAbove``). A redraw that touches anything between this and ``drawMaxY`` must draw
    /// the fragment, and a change to the fragment must repaint all of it.
    public let drawMinY: CGFloat

    /// The bottom of the fragment's pixels: its rect's bottom, lowered by any ink reaching below it.
    public let drawMaxY: CGFloat

    @inlinable
    public init(fragment: LineFragment, xPos: CGFloat, yPos: CGFloat, width: CGFloat, height: CGFloat) {
        self.fragment = fragment
        self.xPos = xPos
        self.yPos = yPos
        self.width = width
        self.height = height
        self.drawMinY = yPos - fragment.inkOverflowAbove
        self.drawMaxY = yPos + height + fragment.inkOverflowBelow
    }

    /// The rect occupied by this fragment in the text view's coordinate space.
    @inlinable
    public var rect: CGRect {
        CGRect(x: xPos, y: yPos, width: width, height: height)
    }
}
