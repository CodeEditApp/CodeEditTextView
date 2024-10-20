//
//  TextView+ItemBox.swift
//  CodeEditTextView
//
//  Created by Abe Malla on 6/18/24.
//

import AppKit
import SwiftUI

public protocol ItemBoxEntry {
    var view: NSView { get }
}

public final class ItemBoxWindowController: NSWindowController {

    public static let DEFAULT_SIZE = NSSize(width: 300, height: 212)

    public var items: [any ItemBoxEntry] = [] {
        didSet {
            updateItems()
        }
    }

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var localEventMonitor: Any?

    public var isVisible: Bool {
        return window?.isVisible ?? false
    }

    public init() {
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint.zero, size: ItemBoxWindowController.DEFAULT_SIZE),
            styleMask: [.resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Style window
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

        // Style the content with custom borders and colors
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = CGColor(
            srgbRed: 31.0 / 255.0, green: 31.0 / 255.0, blue: 36.0 / 255.0, alpha: 1.0
        )
        window.contentView?.layer?.cornerRadius = 8
        window.contentView?.layer?.borderWidth = 1
        window.contentView?.layer?.borderColor = NSColor.gray.withAlphaComponent(0.4).cgColor
        let innerShadow = NSShadow()
        innerShadow.shadowColor = NSColor.black.withAlphaComponent(0.1)
        innerShadow.shadowOffset = NSSize(width: 0, height: -1)
        innerShadow.shadowBlurRadius = 2
        window.contentView?.shadow = innerShadow

        super.init(window: window)

        setupTableView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Opens the window of items
    public func show() {
        super.showWindow(nil)
        setupEventMonitor()
    }

    public func showWindow(attachedTo parentWindow: NSWindow) {
        guard let window = self.window else { return }
        parentWindow.addChildWindow(window, ordered: .above)
        window.orderFront(nil)

        // Close on window switch
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: parentWindow,
            queue: .current
        ) { [weak self] _ in
            self?.close()
        }

        self.show()
    }

    public override func close() {
        guard isVisible else { return }
        removeEventMonitor()
        super.close()
    }

    private func setupTableView() {
        tableView.delegate = self
        tableView.dataSource = self
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.enclosingScrollView?.drawsBackground = false
        tableView.rowHeight = 24

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ItemsCell"))
        column.width = ItemBoxWindowController.DEFAULT_SIZE.width
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.verticalScroller?.controlSize = .large
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        window?.contentView?.addSubview(scrollView)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                scrollView.topAnchor.constraint(equalTo: window!.contentView!.topAnchor),
                scrollView.leadingAnchor.constraint(equalTo: window!.contentView!.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: window!.contentView!.trailingAnchor),
                scrollView.bottomAnchor.constraint(equalTo: window!.contentView!.bottomAnchor)
            ])
    }

    private func updateItems() {
        tableView.reloadData()
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        tableView.enumerateAvailableRowViews { (rowView, row) in
            if let cellView = rowView.view(atColumn: 0) as? CustomTableCellView {
                cellView.backgroundStyle = tableView.selectedRow == row ? .emphasized : .normal
            }
        }
    }

    private func setupEventMonitor() {
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self = self else { return event }

            switch event.type {
            case .keyDown:
                switch event.keyCode {
                case 53: // Escape key
                    self.close()
                case 125: // Down arrow
                    self.selectNextItemInTable()
                    return nil
                case 126: // Up arrow
                    self.selectPreviousItemInTable()
                    return nil
                case 36: // Return key
                    return nil
                default:
                    break
                }
            case .leftMouseDown, .rightMouseDown:
                // If we click outside the window, close the window
                if !NSMouseInRect(NSEvent.mouseLocation, self.window!.frame, false) {
                    self.close()
                }
            default:
                break
            }

            return event
        }
    }

    private func removeEventMonitor() {
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
    }

    private func selectNextItemInTable() {
        let nextIndex = min(tableView.selectedRow + 1, items.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: nextIndex), byExtendingSelection: false)
        tableView.scrollRowToVisible(nextIndex)
    }

    private func selectPreviousItemInTable() {
        let previousIndex = max(tableView.selectedRow - 1, 0)
        tableView.selectRowIndexes(IndexSet(integer: previousIndex), byExtendingSelection: false)
        tableView.scrollRowToVisible(previousIndex)
    }

    deinit {
        removeEventMonitor()
    }
}

extension ItemBoxWindowController: NSTableViewDataSource {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        return items.count
    }
}

extension ItemBoxWindowController: NSTableViewDelegate {
//    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
//        items[row].view
//    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cellIdentifier = NSUserInterfaceItemIdentifier("CustomCell")
        var cell = tableView.makeView(withIdentifier: cellIdentifier, owner: nil) as? CustomTableCellView

        if cell == nil {
            cell = CustomTableCellView(frame: .zero)
            cell?.identifier = cellIdentifier
        }

        // Remove any existing subviews
        cell?.subviews.forEach { $0.removeFromSuperview() }

        let itemView = items[row].view
        cell?.addSubview(itemView)
        itemView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            itemView.topAnchor.constraint(equalTo: cell!.topAnchor),
            itemView.leadingAnchor.constraint(equalTo: cell!.leadingAnchor, constant: 4),
            itemView.trailingAnchor.constraint(equalTo: cell!.trailingAnchor, constant: -4),
            itemView.bottomAnchor.constraint(equalTo: cell!.bottomAnchor)
        ])

        return cell
    }
}

private class CustomTableCellView: NSTableCellView {
    private let backgroundView = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 4
        addSubview(backgroundView, positioned: .below, relativeTo: nil)

        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            updateBackgroundColor()
        }
    }

    private func updateBackgroundColor() {
        switch backgroundStyle {
        case .normal:
            backgroundView.layer?.backgroundColor = NSColor.clear.cgColor
        case .emphasized:
            backgroundView.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.5).cgColor
        @unknown default:
            backgroundView.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}
