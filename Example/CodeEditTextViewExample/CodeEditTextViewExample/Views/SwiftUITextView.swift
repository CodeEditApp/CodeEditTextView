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
    @Binding var text: String

    func makeNSViewController(context: Context) -> TextViewController {
        let controller = TextViewController(string: text)
        context.coordinator.controller = controller
        return controller
    }

    func updateNSViewController(_ nsViewController: TextViewController, context: Context) {
        // Do nothing, our binding has to be a one-way binding
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    @MainActor
    public class Coordinator: NSObject {
        weak var controller: TextViewController?
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
            super.init()

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(textViewDidChangeText(_:)),
                name: TextView.textDidChangeNotification,
                object: nil
            )
        }

        @objc func textViewDidChangeText(_ notification: Notification) {
            guard let textView = notification.object as? TextView,
                  let controller,
                  controller.textView === textView else {
                return
            }
            text.wrappedValue = textView.string
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
