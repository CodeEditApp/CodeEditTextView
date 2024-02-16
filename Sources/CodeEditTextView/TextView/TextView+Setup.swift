//
//  TextView+Setup.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 9/15/23.
//

import AppKit

extension TextView {
    func setUpLayoutManager(lineHeightMultiplier: CGFloat, wrapLines: Bool) -> TextLayoutManager {
        TextLayoutManager(
            textStorage: textStorage,
            lineHeightMultiplier: lineHeightMultiplier,
            wrapLines: wrapLines,
            textView: self,
            delegate: self
        )
    }

    func setUpSelectionManager() -> TextSelectionManager {
        TextSelectionManager(
            layoutManager: layoutManager,
            textStorage: textStorage,
            textView: self,
            delegate: self
        )
    }

    func setUpScrollListeners(scrollView: NSScrollView) {
        NotificationCenter.default.removeObserver(self, name: NSScrollView.willStartLiveScrollNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSScrollView.didEndLiveScrollNotification, object: nil)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewWillStartScroll),
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidEndScroll),
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )
    }

    @objc func scrollViewWillStartScroll() {
        if #available(macOS 14.0, *) {
            inputContext?.textInputClientWillStartScrollingOrZooming()
        }
    }

    @objc func scrollViewDidEndScroll() {
        if #available(macOS 14.0, *) {
            inputContext?.textInputClientDidEndScrollingOrZooming()
        }
    }
}
