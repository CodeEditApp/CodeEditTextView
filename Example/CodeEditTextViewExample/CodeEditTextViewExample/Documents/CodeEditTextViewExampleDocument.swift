//
//  CodeEditTextViewExampleDocument.swift
//  CodeEditTextViewExample
//
//  Created by Khan Winter on 1/9/25.
//

import SwiftUI
import UniformTypeIdentifiers

struct CodeEditTextViewExampleDocument: FileDocument {
    var text: String

    init(text: String = "") {
        self.text = text
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
        text = String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = Data(text.utf8)
        return .init(regularFileWithContents: data)
    }
}
