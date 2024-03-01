//
//  TextLayoutManager+Transaction.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 2/24/24.
//

import Foundation

extension TextLayoutManager {
    /// Begins a transaction, preventing the layout manager from performing layout until the `endTransaction` is called.
    /// Useful for grouping attribute modifications into one layout pass rather than laying out every update.
    ///
    /// You can nest transaction start/end calls, the layout manager will not cause layout until the last transaction
    /// group is ended.
    ///
    /// Ensure there is a balanced number of begin/end calls. If there is a missing endTranscaction call, the layout
    /// manager will never lay out text. If there is a end call without matching a start call an assertionFailure
    /// will occur.
    public func beginTransaction() {
        transactionCounter += 1
    }

    /// Ends a transaction. When called, the layout manager will layout any necessary lines.
    public func endTransaction(forceLayout: Bool = false) {
        transactionCounter -= 1
        if transactionCounter == 0 {
            if forceLayout {
                setNeedsLayout()
            }
            layoutLines()
        } else if transactionCounter < 0 {
            assertionFailure(
                "TextLayoutManager.endTransaction called without a matching TextLayoutManager.beginTransaction call"
            )
        }
    }
}
