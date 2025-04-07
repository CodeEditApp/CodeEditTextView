//
//  TextView+Lifecycle.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 4/7/25.
//

extension TextView {
    override public func layout() {
        layoutManager.layoutLines()
        super.layout()
    }

    override public func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        layoutManager.layoutLines()
    }

    override public func viewWillMove(toSuperview newSuperview: NSView?) {
        guard let scrollView = enclosingScrollView else {
            return
        }

        setUpScrollListeners(scrollView: scrollView)
    }

    override public func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        updateFrameIfNeeded()
    }
}
