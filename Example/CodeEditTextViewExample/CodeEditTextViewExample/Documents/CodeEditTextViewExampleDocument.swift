//
//  CodeEditTextViewExampleDocument.swift
//  CodeEditTextViewExample
//
//  Created by Khan Winter on 1/9/25.
//

import SwiftUI
import UniformTypeIdentifiers

struct CodeEditTextViewExampleDocument: FileDocument, @unchecked Sendable {
    var text: NSTextStorage

    init(text: String = "") {
        self.text = NSTextStorage(string: text)
    }

    static var readableContentTypes: [UTType] {
        [
            .item
        ]
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = try NSTextStorage(
            data: data,
            options: [.characterEncoding: NSUTF8StringEncoding, .fileType: NSAttributedString.DocumentType.plain],
            documentAttributes: nil
        )
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try text.data(for: NSRange(location: 0, length: text.length))
        return .init(regularFileWithContents: data)
    }
}

extension NSAttributedString {
    func data(for range: NSRange) throws -> Data {
        try data(
            from: range,
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.plain,
                .characterEncoding: NSUTF8StringEncoding
            ]
        )
    }
}
