//
//  TextView+Menu.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 8/21/23.
//

import AppKit

extension TextView {
    override public func menu(for event: NSEvent) -> NSMenu? {
        // Control-click enters this method with the original left-mouse-down event.
        guard event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) else {
            return super.menu(for: event)
        }

        let menu = NSMenu()

        menu.items = [
            NSMenuItem(title: "Cut", action: #selector(cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(paste(_:)), keyEquivalent: "v")
        ]

        return menu
    }
}
