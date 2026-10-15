//
//  DraggingTextRenderer.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 11/24/24.
//

import AppKit

class DraggingTextRenderer: NSView {
    let ranges: [NSRange]
    let layoutManager: TextLayoutManager

    /// The line-storage y position of the top of the first selected fragment. Fragments draw relative to this,
    /// so the rendered image is contiguous regardless of any view zones between the selected lines.
    private let contentStartY: CGFloat

    /// The union of all dragged ranges. Lines are enumerated once over this span so fragments shared by
    /// multiple ranges are drawn exactly once.
    private let fullRange: NSRange

    override var isFlipped: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        self.frame.size
    }

    /// - Parameters:
    ///   - ranges: The dragged ranges, sorted ascending by location, non-overlapping.
    ///   - layoutManager: The layout manager the ranges belong to. All ranges must be laid out.
    init?(ranges: [NSRange], layoutManager: TextLayoutManager) {
        self.ranges = ranges
        self.layoutManager = layoutManager

        var minY: CGFloat = .infinity
        var maxY: CGFloat = -.infinity
        var firstLineIndex: Int?

        for range in ranges where !range.isEmpty {
            for line in layoutManager.lineStorage.linesInRange(range) {
                for fragment in line.data.lineFragments {
                    let fragmentRange = fragment.range.translate(location: line.range.location)
                    guard let intersection = fragmentRange.intersection(range), !intersection.isEmpty else {
                        continue
                    }
                    minY = min(minY, line.yPos + fragment.yPos)
                    maxY = max(maxY, line.yPos + fragment.yPos + fragment.height)
                    if firstLineIndex == nil {
                        firstLineIndex = line.index
                    }
                }
            }
        }

        guard let firstLineIndex, minY < maxY,
              let firstRange = ranges.first(where: { !$0.isEmpty }),
              let lastRange = ranges.last(where: { !$0.isEmpty }) else {
            return nil
        }

        self.contentStartY = minY
        self.fullRange = NSRange(start: firstRange.lowerBound, end: lastRange.upperBound)

        // The frame is positioned in the text view's coordinate space, which includes view zone whitespace.
        let frame = CGRect(
            x: layoutManager.edgeInsets.left,
            y: layoutManager.lineStorageYToDocumentY(minY, lineIndex: firstLineIndex),
            width: layoutManager.maxLineWidth,
            height: maxY - minY
        )

        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        let renderer = LineFragmentRenderer(
            textStorage: layoutManager.textStorage,
            invisibleCharacterDelegate: layoutManager.invisibleCharacterDelegate
        )
        for line in layoutManager.lineStorage.linesInRange(fullRange) {
            drawLine(line, context: context, renderer: renderer)
        }
    }

    private func drawLine(
        _ line: TextLineStorage<TextLine>.TextLinePosition,
        context: CGContext,
        renderer: LineFragmentRenderer
    ) {
        for fragment in line.data.lineFragments {
            let fragmentRange = fragment.range.translate(location: line.range.location)
            let fragmentOffset = fragmentRange.location

            // The selected x intervals in this fragment, gathered across every dragged range so a fragment
            // shared by multiple ranges is drawn once and masked once.
            var selectedIntervals: [(minX: CGFloat, maxX: CGFloat)] = []
            for range in ranges {
                guard let intersection = fragmentRange.intersection(range), !intersection.isEmpty else {
                    continue
                }
                let startX = layoutManager.characterXPosition(
                    in: fragment.data,
                    for: intersection.lowerBound - fragmentOffset
                )
                let endX = layoutManager.characterXPosition(
                    in: fragment.data,
                    for: intersection.upperBound - fragmentOffset
                )
                selectedIntervals.append((min(startX, endX), max(startX, endX)))
            }

            guard !selectedIntervals.isEmpty else {
                continue
            }
            selectedIntervals.sort(by: { $0.minX < $1.minX })

            let fragmentYPos = line.yPos + fragment.yPos - contentStartY
            renderer.draw(lineFragment: fragment.data, in: context, yPos: fragmentYPos)

            // Clear everything outside the selected intervals.
            var clearStartX: CGFloat = 0.0
            for interval in selectedIntervals {
                if interval.minX > clearStartX {
                    context.clear(
                        CGRect(
                            x: clearStartX,
                            y: fragmentYPos,
                            width: interval.minX - clearStartX,
                            height: fragment.height
                        ).pixelAligned
                    )
                }
                clearStartX = max(clearStartX, interval.maxX)
            }
            if clearStartX < frame.width {
                context.clear(
                    CGRect(
                        x: clearStartX,
                        y: fragmentYPos,
                        width: frame.width - clearStartX,
                        height: fragment.height
                    ).pixelAligned
                )
            }
        }
    }
}
