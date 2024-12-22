//
//  ItemBoxWindowController+Window.swift
//  CodeEditTextView
//
//  Created by Abe Malla on 12/22/24.
//

extension ItemBoxWindowController {
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


    private func configureNoItemsLabel() {
        window?.contentView?.addSubview(noItemsLabel)

        NSLayoutConstraint.activate([
            noItemsLabel.centerXAnchor.constraint(equalTo: window!.contentView!.centerXAnchor),
            noItemsLabel.centerYAnchor.constraint(equalTo: window!.contentView!.centerYAnchor)
        ])
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