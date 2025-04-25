//
//  TextAttachmentManager.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 4/24/25.
//

import Foundation

/// Manages a set of attachments for the layout manager, provides methods for efficiently finding attachments for a
/// line range.
///
/// If two attachments are overlapping, the one placed further along in the document will be
/// ignored when laying out attachments.
public final class TextAttachmentManager {
    private var orderedAttachments: [TextAttachmentBox] = []
    
    public func addAttachment(_ attachment: any TextAttachment, for range: NSRange) {
        let box = TextAttachmentBox(range: range, attachment: attachment)
        
        // Insert new box into the ordered list.
        
    }
    
    /// Finds attachments for the given line range, and returns them as an array.
    /// Returned attachment's ranges will be relative to the _document_, not the line.
    public func attachments(forLineRange range: NSRange) -> [TextAttachmentBox] {
        // Use binary search to find start/end index
        
    }
}
