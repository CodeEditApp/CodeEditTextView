//
//  CharacterSet.swift
//  CodeEditTextView
//
//  Created by Abe Malla on 3/29/25.
//

import Foundation

extension CharacterSet {
    static let codeIdentifierCharacters: CharacterSet = .alphanumerics
        .union(.init(charactersIn: "_"))
}
