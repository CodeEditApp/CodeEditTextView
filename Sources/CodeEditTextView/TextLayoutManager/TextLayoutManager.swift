//
//  TextLayoutManager.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 6/21/23.
//

import Foundation
import AppKit

/// The text layout manager manages laying out lines in a code document.
public class TextLayoutManager: NSObject {
    // MARK: - Public Properties

    public weak var delegate: TextLayoutManagerDelegate?
    public var lineHeightMultiplier: CGFloat {
        didSet {
            invalidateLineHeightEstimate()
            setNeedsLayout()
        }
    }
    public var wrapLines: Bool {
        didSet {
            setNeedsLayout()
        }
    }
    public var detectedLineEnding: LineEnding = .lineFeed
    /// The edge insets to inset all text layout with.
    public var edgeInsets: HorizontalEdgeInsets = .zero {
        didSet {
            delegate?.layoutManagerMaxWidthDidChange(newWidth: maxLineWidth + edgeInsets.horizontal)
            setNeedsLayout()
        }
    }

    /// The number of lines in the document
    public var lineCount: Int {
        lineStorage.count
    }

    /// The strategy to use when breaking lines. Defaults to ``LineBreakStrategy/word``.
    public var lineBreakStrategy: LineBreakStrategy = .word {
        didSet {
            setNeedsLayout()
        }
    }

    /// The amount of extra vertical padding used to lay out lines in before they come into view.
    ///
    /// This solves a small problem with layout performance, if you're seeing layout lagging behind while scrolling,
    /// adjusting this value higher may help fix that.
    /// Defaults to `350`.
    public var verticalLayoutPadding: CGFloat = 350 {
        didSet {
            setNeedsLayout()
        }
    }

    public weak var renderDelegate: TextLayoutManagerRenderDelegate? {
        didSet {
            // Rebuild using potentially overridden behavior.
            _estimateLineHeight = nil
            lineStorage.removeAll()
            // Install the delegate's custom renderer, or restore the default when the delegate is removed or
            // declines to provide one - keeping a stale custom renderer would draw with metrics the freshly
            // rebound hot-path closures no longer produce.
            lineFragmentRenderer = renderDelegate?.makeLineFragmentRenderer(
                textStorage: textStorage,
                invisibleCharacterDelegate: invisibleCharacterDelegate
            ) ?? LineFragmentRenderer(
                textStorage: textStorage,
                invisibleCharacterDelegate: invisibleCharacterDelegate
            )
            rebindRenderDelegateHotPath()
            prepareTextLines()
        }
    }

    // MARK: - Hot-path bindings
    //
    // The render delegate's protocol methods are called from tight inner loops (cursor/selection lookups,
    // per-line typesetting). Walking the witness table + weak-ref check on every call is wasted work when most text
    // views don't install a render delegate at all. We pre-bind the overrides here: a single non-escaping closure
    // pointer compared against nil beats an optional-chained protocol call. Kept `@usableFromInline` so the
    // `@inline(__always)` wrapper on `characterXPosition(in:for:)` can inline the branch at client call sites within
    // the module.
    @usableFromInline
    internal var _xPosOverride: ((LineFragment, Int) -> CGFloat)?

    /// Pre-bound closure for `TextLayoutManagerRenderDelegate.prepareForDisplay`. When non-nil the layout loop calls
    /// this instead of going through the protocol witness table. Populated by `rebindRenderDelegateHotPath()`.
    internal var _prepareForDisplayOverride: (
        (TextLine, TextLine.DisplayData, NSRange, NSTextStorage, MarkedRanges?, [AnyTextAttachment]) -> Void
    )?

    private func rebindRenderDelegateHotPath() {
        guard let renderDelegate else {
            _xPosOverride = nil
            _prepareForDisplayOverride = nil
            return
        }
        // Capture the delegate weakly - the delegate outlives us by contract, but a weak capture matches the declared
        // `weak var renderDelegate` lifetime guarantees and is free at call time (one pointer compare).
        _xPosOverride = { [weak renderDelegate] fragment, offset in
            guard let renderDelegate else { return fragment._xPos(for: offset) }
            return renderDelegate.characterXPosition(in: fragment, for: offset)
        }
        _prepareForDisplayOverride = { [weak renderDelegate] textLine, displayData, range, stringRef, marked, added in
            guard let renderDelegate else {
                textLine.prepareForDisplay(
                    displayData: displayData, range: range, stringRef: stringRef,
                    markedRanges: marked, attachments: added
                )
                return
            }
            renderDelegate.prepareForDisplay(
                textLine: textLine, displayData: displayData, range: range, stringRef: stringRef,
                markedRanges: marked, attachments: added
            )
        }
    }

    public let attachments: TextAttachmentManager = TextAttachmentManager()

    /// Manages view zones - horizontal bands of space inserted between lines of text.
    /// View zones are used to display UI elements between lines, such as reference counts,
    /// merge conflict buttons, inline diffs, and other features that need vertical space
    /// in the document flow.
    public let viewZones: ViewZoneManager = ViewZoneManager()

    /// Manages line decorations - visual adornments applied to lines such as backgrounds, glyph margin
    /// indicators, and overview ruler marks.
    public let lineDecorations: LineDecorationManager = LineDecorationManager()

    public weak var invisibleCharacterDelegate: InvisibleCharactersDelegate? {
        didSet {
            lineFragmentRenderer.invisibleCharacterDelegate = invisibleCharacterDelegate
            layoutView?.needsDisplay = true
        }
    }

    // MARK: - Internal

    weak var textStorage: NSTextStorage?
    public var lineStorage: TextLineStorage<TextLine> = TextLineStorage()
    var markedTextManager: MarkedTextManager = MarkedTextManager()

    /// The renderer used to draw line fragments into the text view's graphics context. Replaceable so consumers (e.g.
    /// the minimap) can swap in a subclass with custom drawing. Setting this forces a full redraw.
    public var lineFragmentRenderer: LineFragmentRenderer {
        didSet {
            layoutView?.needsDisplay = true
        }
    }

    /// The list of laid-out fragments currently in (or near) the viewport, in document y order.
    ///
    /// Populated by `layoutLines()`. Consumed by `TextView.draw(_:)` to draw fragments directly into the text view's
    /// graphics context - replaces the per-fragment `NSView` tree we used to maintain.
    public internal(set) var visibleFragments: ContiguousArray<VisibleFragment> = []

    /// The previous pass's `visibleFragments`, kept so `layoutLines(in:)` can detect whether a pass actually
    /// changed anything before dirtying the whole backing store. Swapped (never copied) with `visibleFragments`
    /// at the top of each pass so the buffers are reused allocation-free.
    var previousVisibleFragments: ContiguousArray<VisibleFragment> = []

    /// The furthest any fragment in `visibleFragments` paints above and below its rect. Bounds the search for the
    /// fragments a rect needs drawn.
    var visibleInkOverflow: (above: CGFloat, below: CGFloat) = (0, 0)

    /// Consecutive layout passes whose fragment count stayed far below the fragment buffers' capacity, counted
    /// by ``reclaimFragmentBufferCapacity(liveCount:)``. Any pass that doesn't stay below resets it, so nothing
    /// short of a sustained drop in the working set can hand the buffers' high-water capacity back.
    var smallFragmentPassRun: Int = 0

    /// The region of `layoutView` whose pixels are guaranteed to show the *current* `visibleFragments` content
    /// before they are next displayed - because a draw already committed them, or because they have been
    /// dirtied for the current list and AppKit owes the repaint. `.null` when nothing qualifies.
    ///
    /// The region never reaches outside the viewport (see ``recordRasterized(_:)`` and
    /// ``retainRasterized(within:)``), and AppKit only discards a dirty rect that lies outside the visible
    /// rect - which is the same region - so a pending repaint inside this claim cannot be dropped.
    ///
    /// `visibleFragments` positions are document coordinates, so a pure scroll produces an identical fragment
    /// list - the list alone can never tell us whether newly revealed pixels were ever rasterized. Draw passes
    /// are clipped to AppKit's dirty region, which is usually smaller than the padded layout band, so fragments
    /// routinely exist without pixels. This rect is the missing ground truth: `drawVisibleFragments(in:)` extends
    /// it with every rect it commits, and any change to the fragment list resets it via
    /// ``invalidateRasterizedRegion()``. After a pass that changed nothing, `layoutLines(in:)` still dirties any
    /// part of the viewport this region doesn't cover.
    var rasterizedRegion: NSRect = .null

    // `invalidateRasterizedRegion()`, `recordRasterized(_:)`, and `viewportRect()` live in
    // TextLayoutManager+Invalidation.swift.

    /// Monotonic counter bumped whenever layout changes in a way that may invalidate cached geometry
    /// (forced re-layouts, per-line typesetting, full invalidations). Consumers cache layout-derived data keyed
    /// on this revision and recompute when it changes. Coarse but correct.
    public internal(set) var layoutRevision: UInt64 = 0

    /// Generation number of the layout pass currently running or last run. Every pass that runs stamps each line it
    /// walks with its generation (``TextLine/visibleStamp``), which replaces a `Set<TextLine.ID>` of visible lines:
    /// a line was visible in the previous pass exactly when its stamp equals ``lastCompletedPassGeneration``.
    /// Hashing a UUID into and out of a set cost ~110 ns per line per pass, 10% of an edit-then-layout cycle.
    var passGeneration: UInt32 = 0
    /// The generation of the last completed layout pass, or 0 when no line counts as visible (before the first
    /// pass, and after anything that discards the visible set).
    var lastCompletedPassGeneration: UInt32 = 0

    /// The edits of a multi-range replacement, in the order they were applied (descending location, so each is in
    /// the original document's coordinates), set by the text view just before the storage transaction holding them
    /// ends. `NSTextStorage` reports such a transaction as one edited range spanning all the edits; with these,
    /// ``textStorage(_:didProcessEditing:range:changeInLength:)`` updates only the lines each edit touched instead
    /// of rebuilding every line in that span. Consumed (and cleared) by the next character edit.
    var pendingCharacterEdits: [(range: NSRange, replacementLength: Int)]?
    /// Used to force a complete re-layout using `setNeedsLayout`
    package var needsLayout: Bool = false

    package var transactionCounter: Int = 0

    /// Whether the storage may still have attributes pending lazy fixing since the last document load, and whether
    /// its characters have been edited since then. See `TextLayoutManager+AttributeFixing`.
    var attributesPendingFix: Bool = false
    var editedSinceLoad: Bool = false

    /// Whether or not a modification transaction is currently open. Layout passes are skipped while `true`; a
    /// follow-up pass runs after the outermost transaction ends.
    public var isInTransaction: Bool {
        transactionCounter > 0
    }

    /// Begins a modification transaction. While a transaction is open, ``layoutLines(in:)`` skips its pass so
    /// layout never reads half-applied text storage state (e.g. mid `beginEditing`/`endEditing` batches).
    /// Transactions may be nested; balance every call with ``endTransaction()``.
    public func beginTransaction() {
        transactionCounter += 1
    }

    /// Ends a transaction opened with ``beginTransaction()``. Ending the outermost transaction schedules a layout
    /// pass to pick up any work skipped while the transaction was open.
    public func endTransaction() {
        assert(transactionCounter > 0, "endTransaction() called without a matching beginTransaction()")
        transactionCounter = max(0, transactionCounter - 1)
        if transactionCounter == 0 {
            layoutView?.needsLayout = true
        }
    }

    /// Guards `layoutLines(in:)` against re-entry. Layout calls out to client-extensible code (render delegates,
    /// view zone views); passes re-entering while this is held are skipped via `try()` rather than deadlocking.
    var layoutLock: NSLock = NSLock()

    /// The content height last reported via `TextLayoutManagerDelegate.layoutManagerHeightDidUpdate(newHeight:)`.
    /// `-1` is a sentinel forcing a report on the next pass.
    var lastReportedContentHeight: CGFloat = -1

    weak var layoutView: NSView?

    /// Renders `layoutView` through tiles: a ``TextView``'s own, or those of ``layoutTiles``. Tiles keep their pixels
    /// across passes, so the redraw decision tracks them instead of ``rasterizedRegion``.
    weak var tileManager: TextTileManager?

    /// The tiles of a layout view that is not a ``TextView``; see ``TextLayoutTiles``.
    weak var layoutTiles: TextLayoutTiles?

    /// The tile manager, while the layout view actually renders through it.
    var activeTileManager: TextTileManager? {
        guard let tileManager, tileManager.isActive else { return nil }
        return tileManager
    }

    /// Every pixel the layout view currently holds: its visible rect, and with tiles every tile, wherever it is.
    var drawnRegion: NSRect {
        guard let layoutView else { return .zero }
        var region = layoutView.visibleRect
        if let tiles = activeTileManager {
            for tile in tiles.tiles {
                region = region.union(tile.frame)
            }
        }
        return region.intersection(layoutView.bounds)
    }

    /// Views drawn alongside the layout view that render through tiles following its layout; see
    /// ``TextTileFollower``.
    var tileFollowers: ContiguousArray<WeakTileFollower> = []

    /// The bands the last completed pass laid out. Every fragment overlapping them is in `visibleFragments`.
    var lastPassBands: LayoutPassBands?

    /// The calculated maximum width of all laid out lines.
    /// - Note: This does not indicate *the* maximum width of the text view if all lines have not been laid out.
    ///         This will be updated if it comes across a wider line.
    var maxLineWidth: CGFloat = 0 {
        didSet {
            delegate?.layoutManagerMaxWidthDidChange(newWidth: maxLineWidth + edgeInsets.horizontal)
        }
    }

    /// The maximum width available to lay out lines in, used to determine how much space is available for laying out
    /// lines. Evals to `.greatestFiniteMagnitude` when ``wrapLines`` is `false`.
    public var maxLineLayoutWidth: CGFloat {
        wrapLines ? wrapLinesWidth : .greatestFiniteMagnitude
    }

    /// The width of the space available to draw text fragments when wrapping lines.
    public var wrapLinesWidth: CGFloat {
        (delegate?.textViewportSize().width ?? .greatestFiniteMagnitude) - edgeInsets.horizontal
    }

    // MARK: - Init

    /// Initialize a text layout manager and prepare it for use.
    /// - Parameters:
    ///   - textStorage: The text storage object to use as a data source.
    ///   - lineHeightMultiplier: The multiplier to use for line heights.
    ///   - wrapLines: Set to true to wrap lines to the visible editor width.
    ///   - textView: The view to layout text fragments in.
    ///   - delegate: A delegate for the layout manager.
    public init(
        textStorage: NSTextStorage,
        lineHeightMultiplier: CGFloat,
        wrapLines: Bool,
        textView: NSView,
        delegate: TextLayoutManagerDelegate?,
        renderDelegate: TextLayoutManagerRenderDelegate? = nil,
        invisibleCharacterDelegate: InvisibleCharactersDelegate? = nil
    ) {
        self.textStorage = textStorage
        self.lineHeightMultiplier = lineHeightMultiplier
        self.wrapLines = wrapLines
        self.layoutView = textView
        self.delegate = delegate
        self.renderDelegate = renderDelegate
        self.lineFragmentRenderer = renderDelegate?.makeLineFragmentRenderer(
            textStorage: textStorage,
            invisibleCharacterDelegate: invisibleCharacterDelegate
        ) ?? LineFragmentRenderer(
            textStorage: textStorage,
            invisibleCharacterDelegate: invisibleCharacterDelegate
        )
        self.invisibleCharacterDelegate = invisibleCharacterDelegate
        super.init()
        // `renderDelegate.didSet` is skipped during init because the property is written directly before `super.init`.
        // Manually bind the hot-path closure here so cursor/selection lookups honor any installed override from
        // frame 0.
        rebindRenderDelegateHotPath()
        prepareTextLines()
        attachments.layoutManager = self
        viewZones.onZonesChanged = { [weak self] in
            self?.setNeedsLayout()
        }
        lineDecorations.onDecorationsChanged = { [weak self] in
            self?.layoutView?.needsDisplay = true
        }
    }

    /// Prepares the layout manager for use.
    /// Parses the text storage object into lines and builds the `lineStorage` object from those lines.
    func prepareTextLines() {
        guard lineStorage.count == 0, let textStorage else { return }
        #if DEBUG
        // Grab some performance information if debugging.
        var info = mach_timebase_info()
        guard mach_timebase_info(&info) == KERN_SUCCESS else { return }
        let start = mach_absolute_time()
        #endif

        lineStorage.buildFromTextStorage(textStorage, estimatedLineHeight: estimateLineHeight())
        detectedLineEnding = LineEnding.detectLineEnding(lineStorage: lineStorage, textStorage: textStorage)
        scheduleAttributeFixing()

        #if DEBUG
        let end = mach_absolute_time()
        let elapsed = end - start
        let nanos = elapsed * UInt64(info.numer) / UInt64(info.denom)
        let sec = TimeInterval(nanos) / TimeInterval(NSEC_PER_SEC)
        // This used to be logged every time. However we're now confident enough in the performance of this method
        // that it's not useful to log it anymore unless it's an odd number. Taking ~500ms for a >500k loc file
        // is normal. More than 1s for any document is not normal.
        if sec >= 1 {
            logger.warning("TextLayoutManager built in: \(sec, privacy: .public)s")
        }
        #endif
    }

    /// Lays out `textStorage` from now on, dropping everything laid out for the previous one.
    ///
    /// A layout manager that lays out a text view's storage for another view (a minimap's) needs this when the text
    /// view's storage is replaced (``TextView/setTextStorage(_:)``). It holds its storage weakly, so it would otherwise
    /// keep the old one, and lay out nothing at all once that is gone.
    public func setTextStorage(_ textStorage: NSTextStorage) {
        self.textStorage = textStorage
        reset()
    }

    /// Resets the layout manager to an initial state.
    func reset() {
        lineStorage.removeAll()
        lastCompletedPassGeneration = 0
        visibleFragments.removeAll(keepingCapacity: true)
        previousVisibleFragments.removeAll(keepingCapacity: true)
        maxLineWidth = 0
        lastReportedContentHeight = -1
        markedTextManager.removeAll()
        lineFragmentRenderer.textStorage = textStorage
        lineDecorations.removeAllDecorations()
        // Attachment ranges refer to the old document.
        attachments.removeAll()
        prepareTextLines()
        setNeedsLayout()
    }

    /// Estimates the line height for the current typing attributes.
    /// Takes into account ``TextLayoutManager/lineHeightMultiplier``.
    /// - Returns: The estimated line height.
    public func estimateLineHeight() -> CGFloat {
        if let _estimateLineHeight {
            return _estimateLineHeight
        } else if let estimate = renderDelegate?.estimatedLineHeight() {
            _estimateLineHeight = estimate
            return estimate
        } else {
            let string = NSAttributedString(string: "0", attributes: delegate?.layoutManagerTypingAttributes() ?? [:])
            let typesetter = CTTypesetterCreateWithAttributedString(string)
            let ctLine = CTTypesetterCreateLine(typesetter, CFRangeMake(0, 1))
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading)
            let height = (ascent + descent + leading) * lineHeightMultiplier
            _estimateLineHeight = height
            return height
        }
    }

    /// Clears the cached line height estimate so the next call to ``estimateLineHeight()`` recomputes it from the
    /// current typing attributes and ``lineHeightMultiplier``. Call whenever an input to the estimate changes
    /// (fonts, typing attributes, the render delegate's estimate).
    public func invalidateLineHeightEstimate() {
        _estimateLineHeight = nil
    }

    /// The last known line height estimate. If  set to `nil`, will be recalculated the next time
    /// ``TextLayoutManager/estimateLineHeight()`` is called.
    internal var _estimateLineHeight: CGFloat?

    deinit {
        lineStorage.removeAll()
        layoutView = nil
        delegate = nil
    }
}
