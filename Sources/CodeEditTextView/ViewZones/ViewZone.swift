//
//  ViewZone.swift
//  CodeEditTextView
//
//  Created by Abe Malla on 4/12/26.
//

import AppKit

/// A view zone represents a horizontal band of space inserted between two lines of text in the editor.
/// View zones are used to display UI elements between lines, such as reference counts,
/// merge conflict action buttons, inline diff views, inline chat, and other features that need to
/// occupy space in the flow of the document without being part of the text content.
///
/// View zones are managed by ``ViewZoneManager`` and are integrated into the layout system via
/// ``TextLayoutManager``. They affect vertical positioning of all lines below the zone.
///
/// Modeled after VSCode's `IViewZone` system.
public struct ViewZone: Identifiable {
    /// Unique identifier for this view zone.
    public let id: UUID

    /// The line number after which this zone appears.
    /// A value of `0` means the zone appears before the first line.
    /// Must be >= 0 and <= the number of lines in the document.
    public var afterLineNumber: Int

    /// The height of the zone in points.
    public var heightInPoints: CGFloat

    /// An optional view to display in the zone. If `nil`, the zone is blank whitespace.
    /// The view is managed by the caller; ``ViewZoneManager`` positions it but does not retain it strongly.
    public weak var view: NSView?

    /// Ordinal used to break ties when multiple zones are placed after the same line.
    /// Lower ordinals are placed first (closer to the line above). Defaults to `0`.
    public var ordinal: Int

    /// If `true`, mouse events on the zone's view are suppressed. Defaults to `false`.
    public var suppressMouseDown: Bool

    public init(
        afterLineNumber: Int,
        heightInPoints: CGFloat,
        view: NSView? = nil,
        ordinal: Int = 0,
        suppressMouseDown: Bool = false
    ) {
        self.id = UUID()
        self.afterLineNumber = afterLineNumber
        self.heightInPoints = heightInPoints
        self.view = view
        self.ordinal = ordinal
        self.suppressMouseDown = suppressMouseDown
    }
}
