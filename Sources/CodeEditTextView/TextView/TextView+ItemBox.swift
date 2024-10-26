//
//  TextView+ItemBox.swift
//  CodeEditTextView
//
//  Created by Abe Malla on 6/18/24.
//

import AppKit
import SwiftUI
import LanguageServerProtocol

/// Represents an item that can be displayed in the ItemBox
public protocol ItemBoxEntry {
    var view: NSView { get }
}

private let WINDOW_PADDING: CGFloat = 5

public final class ItemBoxWindowController: NSWindowController {

    // MARK: - Properties

    /// Default size of the window when opened
    public static let DEFAULT_SIZE = NSSize(width: 300, height: 212)

    /// The items to be displayed in the window
    public var items: [any ItemBoxEntry] = [] {
        didSet { updateItems() }
    }

    /// Whether the ItemBox window is visbile
    public var isVisible: Bool {
        window?.isVisible ?? false
    }

    // MARK: - Private Properties

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    /// An event monitor for keyboard events
    private var localEventMonitor: Any?

    // MARK: - Initialization

    public init() {
        let window = Self.makeWindow()
        super.init(window: window)

        configureTableView(tableView)
        configureScrollView(scrollView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Opens the window of items
    public func show() {
        super.showWindow(nil)
        setupEventMonitor()
    }

    /// Opens the window as a child of another window
    public func showWindow(attachedTo parentWindow: NSWindow) {
        guard let window = window else { return }

        parentWindow.addChildWindow(window, ordered: .above)
        window.orderFront(nil)

        // Close on window switch
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(parentWindowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: parentWindow
        )

        self.show()
    }

    /// Close the window
    public override func close() {
        guard isVisible else { return }
        removeEventMonitor()
        super.close()
    }

    // MARK: - Private Methods

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: ItemBoxWindowController.DEFAULT_SIZE),
            styleMask: [.resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configureWindow(window)
        configureWindowContent(window)
        return window
    }

    private static func configureWindow(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isExcludedFromWindowsMenu = true
        window.isReleasedWhenClosed = false
        window.level = .popUpMenu
        window.hasShadow = true
        window.isOpaque = false
        window.tabbingMode = .disallowed
        window.hidesOnDeactivate = true
        window.backgroundColor = .clear
        window.minSize = ItemBoxWindowController.DEFAULT_SIZE
    }

    private static func configureWindowContent(_ window: NSWindow) {
        guard let contentView = window.contentView else { return }

        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = CGColor(
            srgbRed: 31.0 / 255.0,
            green: 31.0 / 255.0,
            blue: 36.0 / 255.0,
            alpha: 1.0
        )
        contentView.layer?.cornerRadius = 8.5
        contentView.layer?.borderWidth = 1
        contentView.layer?.borderColor = NSColor.gray.withAlphaComponent(0.45).cgColor

        let innerShadow = NSShadow()
        innerShadow.shadowColor = NSColor.black.withAlphaComponent(0.1)
        innerShadow.shadowOffset = NSSize(width: 0, height: -1)
        innerShadow.shadowBlurRadius = 2
        contentView.shadow = innerShadow
    }

    private func configureTableView(_ tableView: NSTableView) {
        tableView.delegate = self
        tableView.dataSource = self
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = .zero
        tableView.allowsEmptySelection = false
        tableView.selectionHighlightStyle = .regular
        tableView.style = .plain
        tableView.usesAutomaticRowHeights = false
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 21
        tableView.gridStyleMask = []

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ItemsCell"))
        column.width = ItemBoxWindowController.DEFAULT_SIZE.width
        tableView.addTableColumn(column)
    }

    private func configureScrollView(_ scrollView: NSScrollView) {
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.verticalScroller = NoSlotScroller()
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.verticalScrollElasticity = .allowed
        scrollView.contentInsets = NSEdgeInsets(top: WINDOW_PADDING, left: 0, bottom: WINDOW_PADDING, right: 0)

        guard let contentView = window?.contentView else { return }
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    @objc private func parentWindowDidResignKey() {
        close()
    }

    private func updateItems() {
        tableView.reloadData()
    }

    private func setupEventMonitor() {
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self = self else { return event }

            switch event.type {
            case .keyDown:
                switch event.keyCode {
                case 53: // Escape
                    self.close()
                    return nil
                case 125, 126:  // Down/Up Arrow
                    self.tableView.keyDown(with: event)
                    return nil
                case 36, 48:  // Return/Tab
                    return nil
                default:
                    return event
                }
            case .leftMouseDown, .rightMouseDown:
                // If we click outside the window, close the window
                if !NSMouseInRect(NSEvent.mouseLocation, self.window!.frame, false) {
                    self.close()
                }
                return event
            default:
                return event
            }
        }
    }

    private func removeEventMonitor() {
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
    }

    deinit {
        removeEventMonitor()
    }
}

extension ItemBoxWindowController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        return items.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        items[row].view
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ItemBoxRowView()
    }
}

private class NoSlotScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // Don't draw the knob slot (the scrollbar background)
    }
}

private class ItemBoxRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.saveGState()
        defer { context.restoreGState() }

        // Create a rect that's inset from the edges and has proper padding
        // TODO: We create a new selectionRect instead of using dirtyRect
        // because there is a visual bug when holding down the arrow keys
        // to select the first or last item that draws a clipped rectangular
        // selection highlight shape instead of the whole rectangle. Replace
        // this when it gets fixed.
        let selectionRect = NSRect(
            x: WINDOW_PADDING,
            y: 0,
            width: bounds.width - (WINDOW_PADDING * 2),
            height: bounds.height
        )
        let cornerRadius: CGFloat = 5
        let path = NSBezierPath(roundedRect: selectionRect, xRadius: cornerRadius, yRadius: cornerRadius)
        let selectionColor = NSColor.gray.withAlphaComponent(0.19)

        context.setFillColor(selectionColor.cgColor)
        path.fill()
    }
}
