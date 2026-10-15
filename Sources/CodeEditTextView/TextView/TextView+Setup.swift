//
//  TextView+Setup.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 9/15/23.
//

import AppKit

/// Remembers the viewport geometry the last scroll-driven layout pass ran against.
///
/// A scroll tick that leaves the clip view on a fractional bounds origin makes AppKit post
/// `boundsDidChangeNotification` twice. The second notification carries the same geometry as the first, so the
/// pass it drives rebuilds an identical fragment list and reaches an identical redraw decision - pure waste on
/// the hottest path in the library, since trackpad scrolling is fractional essentially always.
///
/// Instances are owned by the observer closures registered in ``TextView/setUpScrollListeners(scrollView:)``, so
/// re-registering (re-parenting into another clip view) starts from a clean slate.
private final class ViewportPassCoalescer {
    /// Everything a rect-less viewport pass reads: the clip rectangle that defines the on-screen document
    /// region, the insets ``TextView/updateFrameIfNeeded()`` subtracts from the available size, the document
    /// view's own size (which clips the viewport and is what that frame calculation writes), and the window,
    /// whose backing store the committed-pixel record is relative to.
    struct Geometry {
        let clipBounds: NSRect
        let insetTop: CGFloat
        let insetBottom: CGFloat
        let documentSize: CGSize
        let windowID: ObjectIdentifier?

        /// Whether a pass over `other` would read the same geometry this one did.
        ///
        /// The origin tolerance is ``TextLayoutManager/rasterizedCoverageEpsilon``: a strip thinner than that
        /// is one `setNeedsDisplayForUnrasterized(viewport:)` declines to dirty anyway, so a pass over it can
        /// reach no decision the previous pass didn't. Everything else compares exactly - a hairline width
        /// change still re-breaks wrapped lines.
        func matches(_ other: Geometry) -> Bool {
            let hairline = TextLayoutManager.rasterizedCoverageEpsilon
            return abs(clipBounds.origin.x - other.clipBounds.origin.x) <= hairline
                && abs(clipBounds.origin.y - other.clipBounds.origin.y) <= hairline
                && clipBounds.size == other.clipBounds.size
                && insetTop == other.insetTop
                && insetBottom == other.insetBottom
                && documentSize == other.documentSize
                && windowID == other.windowID
        }
    }

    private var lastPass: Geometry?

    /// - Parameters:
    ///   - geometry: The geometry the pass would run against.
    ///   - forced: Set when the layout manager owes a full re-layout, which no geometry comparison can rule out.
    func shouldRunPass(for geometry: Geometry, forced: Bool) -> Bool {
        guard !forced, let lastPass else { return true }
        return !geometry.matches(lastPass)
    }

    /// Credits `geometry` to the pass that just ran, or forgets the last pass entirely when given `nil`.
    func recordPass(_ geometry: Geometry?) {
        lastPass = geometry
    }
}

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
        // This is called every time the view moves to a clip view (eg: re-parenting when moving editor tabs).
        // Remove any previous registrations first so scroll events never fan out to duplicate observers.
        removeScrollListeners()

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

        // One coalescer for both clip-view observers: they answer the same question - has the viewport moved -
        // and AppKit interleaves them freely while a window resizes.
        let coalescer = ViewportPassCoalescer()

        scrollViewObserverTokens.append(
            NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.updatedViewportIfGeometryChanged(coalescer)
            }
        )

        scrollViewObserverTokens.append(
            NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.updatedViewportIfGeometryChanged(coalescer)
            }
        )
    }

    /// Runs a viewport pass unless the geometry that pass would read is the geometry the last one already ran
    /// against.
    ///
    /// Skipping is only ever a no-op repeat: an unchanged clip rectangle exposes no pixel the previous pass's
    /// redraw decision didn't already account for, and that pass's `visibleFragments` still cover the same
    /// viewport (with the layout manager's vertical padding on top). Everything that can invalidate that
    /// reasoning takes the pass instead - a clip move past the hairline the redraw decision itself calls
    /// visible, a size / inset / document-height change, a move between windows, a forced re-layout (`setText`,
    /// attribute and configuration changes), and any pass the layout manager declined because a transaction was
    /// open. A pass the layout manager skipped for re-entry needs no special case here: it leaves the view's
    /// `needsLayout` set, so AppKit's layout phase runs one before the next display.
    private func updatedViewportIfGeometryChanged(_ coalescer: ViewportPassCoalescer) {
        guard let scrollView, let layoutManager else {
            updatedViewport(visibleRect)
            return
        }
        let geometry = ViewportPassCoalescer.Geometry(
            clipBounds: scrollView.contentView.bounds,
            insetTop: scrollView.contentInsets.top,
            insetBottom: scrollView.contentInsets.bottom,
            documentSize: bounds.size,
            windowID: window.map { ObjectIdentifier($0) }
        )
        guard coalescer.shouldRunPass(for: geometry, forced: layoutManager.needsLayout) else { return }
        updatedViewport(visibleRect)
        // A pass entered while a transaction is open is skipped wholesale, so this geometry must not be
        // credited as covered - the notification that follows the transaction has to run one.
        coalescer.recordPass(layoutManager.isInTransaction ? nil : geometry)
    }

    /// Removes all scroll-view notification observers. Block-based tokens must be removed individually -
    /// `NotificationCenter.removeObserver(self)` only unregisters selector-based observers.
    func removeScrollListeners() {
        NotificationCenter.default.removeObserver(
            self,
            name: NSScrollView.willStartLiveScrollNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSScrollView.didEndLiveScrollNotification,
            object: nil
        )
        for token in scrollViewObserverTokens {
            NotificationCenter.default.removeObserver(token)
        }
        scrollViewObserverTokens.removeAll()
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
