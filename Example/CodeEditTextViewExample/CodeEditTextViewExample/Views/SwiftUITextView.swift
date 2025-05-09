//
//  SwiftUITextView.swift
//  CodeEditTextViewExample
//
//  Created by Khan Winter on 1/9/25.
//

import SwiftUI
import AppKit
import CodeEditTextView

struct SwiftUITextView: NSViewControllerRepresentable {
    var text: NSTextStorage
    @Binding var wrapLines: Bool
    @Binding var enableEdgeInsets: Bool

    func makeNSViewController(context: Context) -> TextViewController {
        let controller = TextViewController(string: "")
        controller.textView.setTextStorage(text)
        controller.wrapLines = wrapLines
        controller.enableEdgeInsets = enableEdgeInsets
        return controller
    }

    func updateNSViewController(_ nsViewController: TextViewController, context: Context) {
        nsViewController.wrapLines = wrapLines
        nsViewController.enableEdgeInsets = enableEdgeInsets
    }
}
