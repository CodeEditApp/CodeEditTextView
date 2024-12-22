//
//  TextView+ItemBox.swift
//  CodeEditTextView
//
//  Created by Abe Malla on 6/18/24.
//

import AppKit
import LanguageServerProtocol

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
        label.isHidden = false
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
        configureNoItemsLabel()
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
                return checkKeyDownEvents(event)

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

    private func checkKeyDownEvents(_ event: NSEvent) -> NSEvent? {
        switch event.keyCode {
        case 53: // Escape
            self.close()
            return nil
        case 125, 126:  // Down/Up Arrow
            self.tableView.keyDown(with: event)
            if self.isVisible {
                return nil
            }
            return event
        case 124: // Right Arrow
//          handleRightArrow()
            self.close()
            return event
        case 123: // Left Arrow
            self.close()
            return event
        case 36, 48:  // Return/Tab
            guard tableView.selectedRow >= 0 else { return event }
            let selectedItem = items[tableView.selectedRow]
            self.delegate?.applyCompletionItem(selectedItem)
            self.close()
            return nil
        default:
            return event
        }
    }

    private func handleRightArrow() {
        guard let window = self.window,
              let selectedRow = tableView.selectedRowIndexes.first,
              selectedRow < items.count,
              !popover.isShown else {
            return
        }
        let rowRect = tableView.rect(ofRow: selectedRow)
        let rowRectInWindow = tableView.convert(rowRect, to: nil)
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

    @objc private func tableViewDoubleClick(_ sender: Any) {
        guard tableView.clickedRow >= 0 else { return }
        let selectedItem = items[tableView.clickedRow]
        delegate?.applyCompletionItem(selectedItem)
        self.close()
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
