//
//  ContentView.swift
//  CodeEditTextViewExample
//
//  Created by Khan Winter on 1/9/25.
//

import SwiftUI

struct ContentView: View {
    @Binding var document: CodeEditTextViewExampleDocument
    @AppStorage("wraplines") private var wrapLines: Bool = true
    @AppStorage("edgeinsets") private var enableEdgeInsets: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Wrap Lines", isOn: $wrapLines)
                Toggle("Inset Edges", isOn: $enableEdgeInsets)
                Button {

                } label: {
                    Text("Insert Attachment")
                }

            }
            Divider()
            SwiftUITextView(
                text: document.text,
                wrapLines: $wrapLines,
                enableEdgeInsets: $enableEdgeInsets
            )
        }
    }
}

#Preview {
    ContentView(document: .constant(CodeEditTextViewExampleDocument()))
}
