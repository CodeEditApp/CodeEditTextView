//
//  TextAttachment.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 4/24/25.
//

import AppKit

public struct TextAttachmentBox: Equatable {
    let range: NSRange
    let attachment: any TextAttachment

    var width: CGFloat {
        attachment.width
    }

    public static func ==(_ lhs: TextAttachmentBox, _ rhs: TextAttachmentBox) -> Bool {
        lhs.range == rhs.range && lhs.attachment === rhs.attachment
    }
}

public protocol TextAttachment: AnyObject {
    var width: CGFloat { get }
    func draw(in context: CGContext, rect: NSRect)
}
