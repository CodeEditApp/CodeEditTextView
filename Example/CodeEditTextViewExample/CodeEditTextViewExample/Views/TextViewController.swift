//
//  TextViewController.swift
//  CodeEditTextViewExample
//
//  Created by Khan Winter on 1/9/25.
//

import AppKit
import CodeEditTextView

class TextViewController: NSViewController {
    var scrollView: NSScrollView!
    var textView: TextView!
    var enableEdgeInsets: Bool = false {
        didSet {
            if enableEdgeInsets {
                textView.edgeInsets = .init(left: 20, right: 30)
                textView.textInsets = .init(left: 10, right: 30)
            } else {
                textView.edgeInsets = .zero
                textView.textInsets = .zero
            }
        }
    }
    var wrapLines: Bool = true {
        didSet {
            textView.wrapLines = wrapLines
        }
    }

    init(string: String) {
        textView = TextView(string: string)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        scrollView = NSScrollView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.wrapLines = wrapLines
        if enableEdgeInsets {
            textView.edgeInsets = .init(left: 30, right: 30)
            textView.textInsets = .init(left: 0, right: 30)
        } else {
            textView.edgeInsets = .zero
            textView.textInsets = .zero
        }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = textView
        scrollView.contentView.postsFrameChangedNotifications = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.hasVerticalScroller = true

        self.view = scrollView

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // Layout on scroll change
        NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.textView.updatedViewport(self?.scrollView.documentVisibleRect ?? .zero)
        }

        textView.updateFrameIfNeeded()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
