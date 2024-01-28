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
}
