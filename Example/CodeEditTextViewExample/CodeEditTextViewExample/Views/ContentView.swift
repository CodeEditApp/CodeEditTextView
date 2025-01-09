//
//  ContentView.swift
//  CodeEditTextViewExample
//
//  Created by Khan Winter on 1/9/25.
//

import SwiftUI

struct ContentView: View {
    @Binding var document: CodeEditTextViewExampleDocument

    var body: some View {
        SwiftUITextView(text: $document.text)
    }
}

#Preview {
    ContentView(document: .constant(CodeEditTextViewExampleDocument()))
}
