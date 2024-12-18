//
//  TextView+ItemBox.swift
//  CodeEditTextView
//
//  Created by Abe Malla on 6/18/24.
//

import AppKit
import LanguageServerProtocol

// DOCUMENTATION BAR BEHAVIOR:
// IF THE DOCUMENTATION BAR APPEARS WHEN SELECTING AN ITEM AND IT EXTENDS BELOW THE SCREEN, IT WILL FLIP THE DIRECTION OF THE ENTIRE WINDOW
// IF IT GETS FLIPPED AND THEN THE DOCUMENTATION BAR DISAPPEARS FOR EXAMPLE, IT WONT FLIP BACK EVEN IF THERES SPACE NOW

/// Represents an item that can be displayed in the ItemBox
public protocol ItemBoxEntry {
    var view: NSView { get }
}

/// Padding at top and bottom of the window
private let WINDOW_PADDING: CGFloat = 5

public final class ItemBoxWindowController: NSWindowController {

    // MARK: - Properties

    public static var DEFAULT_SIZE: NSSize {
        NSSize(
            width: 256, // TODO: DOES MIN WIDTH DEPEND ON FONT SIZE?
            height: rowsToWindowHeight(for: 1)
        )
    }

    /// The items to be displayed in the window
    public var items: [CompletionItem] = [] {
        didSet { onItemsUpdated() }
    }

    /// Whether the ItemBox window is visbile
    public var isVisible: Bool {
        window?.isVisible ?? false
    }

    public weak var delegate: ItemBoxDelegate?

    // MARK: - Private Properties

    /// Height of a single row
    private static let ROW_HEIGHT: CGFloat = 21
    /// Maximum number of visible rows (8.5)
    private static let MAX_VISIBLE_ROWS: CGFloat = 8.5

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let popover = NSPopover()
    /// Tracks when the window is placed above the cursor
    private var isWindowAboveCursor = false

    private let noItemsLabel: NSTextField = {
        let label = NSTextField(labelWithString: "No Completions")
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        // TODO: GET FONT SIZE FROM THEME
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        return label
    }()

    /// An event monitor for keyboard events
    private var localEventMonitor: Any?
    
    public static let itemSelectedNotification = NSNotification.Name("ItemBoxItemSelected")

    // MARK: - Initialization

    public init() {
        let window = Self.makeWindow()
        super.init(window: window)
        configureTableView()
        configureScrollView()
        setupNoItemsLabel()
        configurePopover()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Opens the window of items
    private func show() {
        setupEventMonitor()
        resetScrollPosition()
        super.showWindow(nil)
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

    /// Will constrain the window's frame to be within the visible screen
    public func constrainWindowToScreenEdges(cursorRect: NSRect) {
        guard let window = self.window,
              let screenFrame = window.screen?.visibleFrame else {
            return
        }

        let windowSize = window.frame.size
        let padding: CGFloat = 22
        var newWindowOrigin = NSPoint(
            x: cursorRect.origin.x,
            y: cursorRect.origin.y
        )

        // Keep the horizontal position within the screen and some padding
        let minX = screenFrame.minX + padding
        let maxX = screenFrame.maxX - windowSize.width - padding

        if newWindowOrigin.x < minX {
            newWindowOrigin.x = minX
        } else if newWindowOrigin.x > maxX {
            newWindowOrigin.x = maxX
        }

        // Check if the window will go below the screen
        // We determine whether the window drops down or upwards by choosing which
        // corner of the window we will position: `setFrameOrigin` or `setFrameTopLeftPoint`
        if newWindowOrigin.y - windowSize.height < screenFrame.minY {
            // If the cursor itself is below the screen, then position the window
            // at the bottom of the screen with some padding
            if newWindowOrigin.y < screenFrame.minY {
                newWindowOrigin.y = screenFrame.minY + padding
            } else {
                // Place above the cursor
                newWindowOrigin.y += cursorRect.height
            }

            isWindowAboveCursor = true
            window.setFrameOrigin(newWindowOrigin)
        } else {
            // If the window goes above the screen, position it below the screen with padding
            let maxY = screenFrame.maxY - padding
            if newWindowOrigin.y > maxY {
                newWindowOrigin.y = maxY
            }

            isWindowAboveCursor = false
            window.setFrameTopLeftPoint(newWindowOrigin)
        }
    }

    // MARK: - Private Methods

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: self.DEFAULT_SIZE),
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
        window.minSize = Self.DEFAULT_SIZE
    }

    private static func configureWindowContent(_ window: NSWindow) {
        guard let contentView = window.contentView else { return }

        contentView.wantsLayer = true
        // TODO: GET COLOR FROM THEME
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

    private func configureTableView() {
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
        tableView.addTableColumn(column)
    }

    private func configureScrollView() {
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

    private func configurePopover() {
//        popover.behavior = .transient
//        popover.animates = true

        // Create and configure the popover content
        let contentViewController = NSViewController()
        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false

        let textField = NSTextField(labelWithString: "Example Documentation\nThis is some example documentation text.")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byWordWrapping
        textField.preferredMaxLayoutWidth = 300
        textField.cell?.wraps = true
        textField.cell?.isScrollable = false

        contentView.addSubview(textField)

        NSLayoutConstraint.activate([
            textField.topAnchor.constraint(equalTo: contentView.topAnchor),
            textField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            textField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            textField.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            contentView.widthAnchor.constraint(equalToConstant: 300)
        ])

        contentViewController.view = contentView
        popover.contentViewController = contentViewController
    }

    private func setupNoItemsLabel() {
        window?.contentView?.addSubview(noItemsLabel)

        NSLayoutConstraint.activate([
            noItemsLabel.centerXAnchor.constraint(equalTo: window!.contentView!.centerXAnchor),
            noItemsLabel.centerYAnchor.constraint(equalTo: window!.contentView!.centerYAnchor)
        ])
    }

    @objc private func parentWindowDidResignKey() {
        close()
    }

    private func onItemsUpdated() {
        updateItemBoxWindowAndContents()
        resetScrollPosition()
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
                case 124: // Right Arrow
//                    handleRightArrow()
                    return event
                case 123: // Left Arrow
                    return event
                case 36, 48:  // Return/Tab
                    // TODO: TEMPORARY
                    let selectedItem = items[tableView.selectedRow]
                    self.delegate?.applyCompletionItem(selectedItem)

                    if items.count > 0 {
                        var nextRow = tableView.selectedRow
                        if nextRow == items.count - 1 && items.count > 1 {
                            nextRow -= 1
                        }
                        items.remove(at: tableView.selectedRow)
                        if nextRow < items.count {
                            tableView.selectRowIndexes(IndexSet(integer: nextRow), byExtendingSelection: false)
                            tableView.scrollRowToVisible(nextRow)
                        }
                    }
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

    private func handleRightArrow() {
        guard let window = self.window,
              let selectedRow = tableView.selectedRowIndexes.first,
              selectedRow < items.count,
              !popover.isShown else {
            return
        }

        // Get the rect of the selected row in window coordinates
        let rowRect = tableView.rect(ofRow: selectedRow)
        let rowRectInWindow = tableView.convert(rowRect, to: nil)
        // Calculate the point where the popover should appear
        let popoverPoint = NSPoint(
            x: window.frame.maxX,
            y: window.frame.minY + rowRectInWindow.midY
        )
        popover.show(
            relativeTo: NSRect(x: popoverPoint.x, y: popoverPoint.y, width: 1, height: 1),
            of: window.contentView!,
            preferredEdge: .maxX
        )
    }

    /// Updates the item box window's height based on the number of items.
    /// If there are no items, the default label will be displayed instead.
    private func updateItemBoxWindowAndContents() {
        guard let window = self.window else {
            return
        }

        noItemsLabel.isHidden = !items.isEmpty
        scrollView.isHidden = items.isEmpty

        // Update window dimensions
        let numberOfVisibleRows = min(CGFloat(items.count), Self.MAX_VISIBLE_ROWS)
        let newHeight = items.count == 0 ?
            Self.rowsToWindowHeight(for: 1) : // Height for 1 row when empty
            Self.rowsToWindowHeight(for: numberOfVisibleRows)

        let currentFrame = window.frame
        if isWindowAboveCursor {
            // When window is above cursor, maintain the bottom position
            let bottomY = currentFrame.minY
            let newFrame = NSRect(
                x: currentFrame.minX,
                y: bottomY,
                width: currentFrame.width,
                height: newHeight
            )
            window.setFrame(newFrame, display: true)
        } else {
            // When window is below cursor, maintain the top position
            window.setContentSize(NSSize(width: currentFrame.width, height: newHeight))
        }

        // Dont allow vertical resizing
        window.maxSize = NSSize(width: CGFloat.infinity, height: newHeight)
        window.minSize = NSSize(width: Self.DEFAULT_SIZE.width, height: newHeight)
    }

    /// Calculate the window height for a given number of rows.
    private static func rowsToWindowHeight(for numberOfRows: CGFloat) -> CGFloat {
        let wholeRows = floor(numberOfRows)
        let partialRow = numberOfRows - wholeRows

        let baseHeight = ROW_HEIGHT * wholeRows
        let partialHeight = partialRow > 0 ? ROW_HEIGHT * partialRow : 0

        // Add window padding only for whole numbers
        let padding = numberOfRows.truncatingRemainder(dividingBy: 1) == 0 ? WINDOW_PADDING * 2 : WINDOW_PADDING

        return baseHeight + partialHeight + padding
    }

    private func resetScrollPosition() {
        guard let clipView = scrollView.contentView as? NSClipView else { return }

        // Scroll to the top of the content
        clipView.scroll(to: NSPoint(x: 0, y: -WINDOW_PADDING))

        // Select the first item
        if !items.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
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
        (items[row] as? any ItemBoxEntry)?.view
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ItemBoxRowView()
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        // Only allow selection through keyboard navigation or single clicks
        let event = NSApp.currentEvent
        if event?.type == .leftMouseDragged {
            return false
        }
        return true
    }
}

private class NoSlotScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // Don't draw the knob slot (the background track behind the knob)
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
        // to select the first or last item, which draws a clipped
        // rectangular highlight shape instead of the whole rectangle.
        // Replace this when it gets fixed.
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

public protocol ItemBoxDelegate: AnyObject {
    func applyCompletionItem(_ item: CompletionItem)
}
