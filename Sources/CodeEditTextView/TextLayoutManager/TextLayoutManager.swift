//
//  TextLayoutManager.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 6/21/23.
//

import Foundation
import AppKit

public protocol TextLayoutManagerDelegate: AnyObject {
    func layoutManagerHeightDidUpdate(newHeight: CGFloat)
    func layoutManagerMaxWidthDidChange(newWidth: CGFloat)
    func layoutManagerTypingAttributes() -> [NSAttributedString.Key: Any]
    func textViewportSize() -> CGSize
    func layoutManagerYAdjustment(_ yAdjustment: CGFloat)

    var visibleRect: NSRect { get }
}

/// The text layout manager manages laying out lines in a code document.
public class TextLayoutManager: NSObject {
    // MARK: - Public Properties

    public weak var delegate: TextLayoutManagerDelegate?
    public var lineHeightMultiplier: CGFloat {
        didSet {
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

    // MARK: - Internal

    weak var textStorage: NSTextStorage?
    var lineStorage: TextLineStorage<TextLine> = TextLineStorage()
    var markedTextManager: MarkedTextManager = MarkedTextManager()
    private let viewReuseQueue: ViewReuseQueue<LineFragmentView, UUID> = ViewReuseQueue()
    package var visibleLineIds: Set<TextLine.ID> = []
    /// Used to force a complete re-layout using `setNeedsLayout`
    package var needsLayout: Bool = false

    package var transactionCounter: Int = 0
    public var isInTransaction: Bool {
        transactionCounter > 0
    }
    #if DEBUG
    /// Guard variable for an assertion check in debug builds.
    /// Ensures that layout calls are not overlapping, potentially causing layout issues.
    /// This is used over a lock, as locks in performant code such as this would be detrimental to performance.
    /// Also only included in debug builds. DO NOT USE for checking if layout is active or not. That is an anti-pattern.
    private var isInLayout: Bool = false
    #endif

    weak var layoutView: NSView?

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
    var maxLineLayoutWidth: CGFloat {
        wrapLines ? wrapLinesWidth : .greatestFiniteMagnitude
    }

    /// The width of the space available to draw text fragments when wrapping lines.
    var wrapLinesWidth: CGFloat {
        (delegate?.textViewportSize().width ?? .greatestFiniteMagnitude) - edgeInsets.horizontal
    }

    /// Contains all data required to perform layout on a text line.
    private struct LineLayoutData {
        let minY: CGFloat
        let maxY: CGFloat
        let maxWidth: CGFloat
    }

    // MARK: - Init

    /// Initialize a text layout manager and prepare it for use.
    /// - Parameters:
    ///   - textStorage: The text storage object to use as a data source.
    ///   - lineHeightMultiplier: The multiplier to use for line heights.
    ///   - wrapLines: Set to true to wrap lines to the visible editor width.
    ///   - textView: The view to layout text fragments in.
    ///   - delegate: A delegate for the layout manager.
    init(
        textStorage: NSTextStorage,
        lineHeightMultiplier: CGFloat,
        wrapLines: Bool,
        textView: NSView,
        delegate: TextLayoutManagerDelegate?
    ) {
        self.textStorage = textStorage
        self.lineHeightMultiplier = lineHeightMultiplier
        self.wrapLines = wrapLines
        self.layoutView = textView
        self.delegate = delegate
        super.init()
        prepareTextLines()
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

        #if DEBUG
        let end = mach_absolute_time()
        let elapsed = end - start
        let nanos = elapsed * UInt64(info.numer) / UInt64(info.denom)
        let msec = TimeInterval(nanos) / TimeInterval(NSEC_PER_MSEC)
        logger.info("TextLayoutManager built in: \(msec, privacy: .public)ms")
        #endif
    }

    /// Resets the layout manager to an initial state.
    func reset() {
        lineStorage.removeAll()
        visibleLineIds.removeAll()
        viewReuseQueue.queuedViews.removeAll()
        viewReuseQueue.usedViews.removeAll()
        maxLineWidth = 0
        markedTextManager.removeAll()
        prepareTextLines()
        setNeedsLayout()
    }

    /// Estimates the line height for the current typing attributes.
    /// Takes into account ``TextLayoutManager/lineHeightMultiplier``.
    /// - Returns: The estimated line height.
    public func estimateLineHeight() -> CGFloat {
        if let _estimateLineHeight {
            return _estimateLineHeight
        } else {
            let string = NSAttributedString(string: "0", attributes: delegate?.layoutManagerTypingAttributes() ?? [:])
            let typesetter = CTTypesetterCreateWithAttributedString(string)
            let ctLine = CTTypesetterCreateLine(typesetter, CFRangeMake(0, 1))
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading)
            _estimateLineHeight = (ascent + descent + leading) * lineHeightMultiplier
            return _estimateLineHeight!
        }
    }

    /// The last known line height estimate. If  set to `nil`, will be recalculated the next time
    /// ``TextLayoutManager/estimateLineHeight()`` is called.
    private var _estimateLineHeight: CGFloat?

    // MARK: - Layout

    /// Asserts that the caller is not in an active layout pass.
    /// See docs on ``isInLayout`` for more details.
    private func assertNotInLayout() {
        #if DEBUG // This is redundant, but it keeps the flag debug-only too which helps prevent misuse.
        assert(!isInLayout, "layoutLines called while already in a layout pass. This is a programmer error.")
        #endif
    }

    /// Lays out all visible lines
    func layoutLines(in rect: NSRect? = nil) { // swiftlint:disable:this function_body_length
        assertNotInLayout()
        guard let visibleRect = rect ?? delegate?.visibleRect,
              !isInTransaction,
              let textStorage else {
            return
        }
        #if DEBUG
        isInLayout = true
        #endif
        let minY = max(visibleRect.minY - verticalLayoutPadding, 0)
        let maxY = max(visibleRect.maxY + verticalLayoutPadding, 0)
        let originalHeight = lineStorage.height
        var usedFragmentIDs = Set<UUID>()
        var forceLayout: Bool = needsLayout
        var newVisibleLines: Set<TextLine.ID> = []
        var yContentAdjustment: CGFloat = 0
        var maxFoundLineWidth = maxLineWidth

        // Layout all lines, fetching lines lazily as they are laid out.
        for linePosition in lineStorage.linesStartingAt(minY, until: maxY).lazy {
            guard linePosition.yPos < maxY else { break }
            if forceLayout
                || linePosition.data.needsLayout(maxWidth: maxLineLayoutWidth)
                || !visibleLineIds.contains(linePosition.data.id) {
                let lineSize = layoutLine(
                    linePosition,
                    textStorage: textStorage,
                    layoutData: LineLayoutData(minY: minY, maxY: maxY, maxWidth: maxLineLayoutWidth),
                    laidOutFragmentIDs: &usedFragmentIDs
                )
                if lineSize.height != linePosition.height {
                    lineStorage.update(
                        atIndex: linePosition.range.location,
                        delta: 0,
                        deltaHeight: lineSize.height - linePosition.height
                    )
                    // If we've updated a line's height, force re-layout for the rest of the pass.
                    forceLayout = true

                    if linePosition.yPos < minY {
                        // Adjust the scroll position by the difference between the new height and old.
                        yContentAdjustment += lineSize.height - linePosition.height
                    }
                }
                if maxFoundLineWidth < lineSize.width {
                    maxFoundLineWidth = lineSize.width
                }
            } else {
                // Make sure the used fragment views aren't dequeued.
                usedFragmentIDs.formUnion(linePosition.data.lineFragments.map(\.data.id))
            }
            newVisibleLines.insert(linePosition.data.id)
        }

        // Enqueue any lines not used in this layout pass.
        viewReuseQueue.enqueueViews(notInSet: usedFragmentIDs)

        // Update the visible lines with the new set.
        visibleLineIds = newVisibleLines

        #if DEBUG
        isInLayout = false
        #endif

        // These are fine to update outside of `isInLayout` as our internal data structures are finalized at this point
        // so laying out again won't break our line storage or visible line.

        if maxFoundLineWidth > maxLineWidth {
            maxLineWidth = maxFoundLineWidth
        }

        if yContentAdjustment != 0 {
            delegate?.layoutManagerYAdjustment(yContentAdjustment)
        }

        if originalHeight != lineStorage.height || layoutView?.frame.size.height != lineStorage.height {
            delegate?.layoutManagerHeightDidUpdate(newHeight: lineStorage.height)
        }

        needsLayout = false
    }

    /// Lays out a single text line.
    /// - Parameters:
    ///   - position: The line position from storage to use for layout.
    ///   - textStorage: The text storage object to use for text info.
    ///   - layoutData: The information required to perform layout for the given line.
    ///   - laidOutFragmentIDs: Updated by this method as line fragments are laid out.
    /// - Returns: A `CGSize` representing the max width and total height of the laid out portion of the line.
    private func layoutLine(
        _ position: TextLineStorage<TextLine>.TextLinePosition,
        textStorage: NSTextStorage,
        layoutData: LineLayoutData,
        laidOutFragmentIDs: inout Set<UUID>
    ) -> CGSize {
        let lineDisplayData = TextLine.DisplayData(
            maxWidth: layoutData.maxWidth,
            lineHeightMultiplier: lineHeightMultiplier,
            estimatedLineHeight: estimateLineHeight()
        )

        let line = position.data
        line.prepareForDisplay(
            displayData: lineDisplayData,
            range: position.range,
            stringRef: textStorage,
            markedRanges: markedTextManager.markedRanges(in: position.range),
            breakStrategy: lineBreakStrategy
        )

        if position.range.isEmpty {
            return CGSize(width: 0, height: estimateLineHeight())
        }

        var height: CGFloat = 0
        var width: CGFloat = 0
        let relativeMinY = max(layoutData.minY - position.yPos, 0)
        let relativeMaxY = max(layoutData.maxY - position.yPos, relativeMinY)

        for lineFragmentPosition in line.lineFragments.linesStartingAt(
            relativeMinY,
            until: relativeMaxY
        ) {
            let lineFragment = lineFragmentPosition.data

            layoutFragmentView(for: lineFragmentPosition, at: position.yPos + lineFragmentPosition.yPos)

            width = max(width, lineFragment.width)
            height += lineFragment.scaledHeight
            laidOutFragmentIDs.insert(lineFragment.id)
        }

        return CGSize(width: width, height: height)
    }

    /// Lays out a line fragment view for the given line fragment at the specified y value.
    /// - Parameters:
    ///   - lineFragment: The line fragment position to lay out a view for.
    ///   - yPos: The y value at which the line should begin.
    private func layoutFragmentView(
        for lineFragment: TextLineStorage<LineFragment>.TextLinePosition,
        at yPos: CGFloat
    ) {
        let view = viewReuseQueue.getOrCreateView(forKey: lineFragment.data.id)
        view.setLineFragment(lineFragment.data)
        view.frame.origin = CGPoint(x: edgeInsets.left, y: yPos)
        layoutView?.addSubview(view)
        view.needsDisplay = true
    }

    deinit {
        lineStorage.removeAll()
        layoutView = nil
        delegate = nil
    }
}
