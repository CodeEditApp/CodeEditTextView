//
//  TextView+Lifecycle.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 4/7/25.
//

import AppKit

extension TextView {
    override public func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // A window change can swap or discard the backing store, so pixels committed in the old window must not
        // satisfy the next pass's rasterized-region check.
        layoutManager.invalidateRasterizedRegion()
        // AppKit calls this *before* inserting the view, so a view being added to a window has no superview yet and
        // no viewport to lay out against. A pass here would replace `visibleFragments` with a list for the wrong
        // region; the pass that matters runs once the view is in its clip view and knows where it is on screen.
        guard superview != nil else {
            needsLayout = true
            return
        }
        layoutManager.layoutLines()
    }

    override public func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        // `clipView` is the *incoming* superview - prefer its scroll view. At this point the view may still be
        // attached to its previous hierarchy, so `enclosingScrollView` can resolve to the OLD scroll view.
        guard let clipView = newSuperview as? NSClipView,
              let scrollView = clipView.enclosingScrollView ?? enclosingScrollView else {
            // Leaving a clip view. The old scroll view's observers outlive the hosting relationship they were
            // registered for, and would go on driving viewport passes for a clip rectangle that no longer says
            // anything about where this view is on screen.
            removeScrollListeners()
            return
        }

        setUpScrollListeners(scrollView: scrollView)
    }

    override public func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        updateFrameIfNeeded()
    }
}
