//
//  UniqueIdentifier.swift
//  CodeEditTextView
//

import Foundation
import CodeEditTextViewObjC

/// Cheap process-unique identifiers for hot object types.
///
/// `UUID()` draws sixteen random bytes from the system generator on every call, about 230ns. Creating the
/// 26k `TextLine`s of a 2MB document spent 6ms of its 11ms on identifiers alone. Identifiers made here
/// combine a per-process random prefix with a relaxed atomic counter: a few nanoseconds, unique for the
/// life of the process, and still unique across processes in practice (64 random prefix bits) when they
/// end up in logs. They keep the `UUID` type so public `Identifiable` conformances are unchanged; they
/// are not RFC 4122 UUIDs and should not be parsed as such.
enum UniqueIdentifier {
    /// Drawn once per process from the system generator.
    private static let prefix = UInt64.random(in: .min ... .max)

    /// A new identifier: the 8-byte process prefix followed by the big-endian counter.
    @inline(__always)
    static func makeUUID() -> UUID {
        let counter = CETVNextUniqueIdentifier()
        let prefix = Self.prefix
        return UUID(uuid: (
            byte(prefix, 56), byte(prefix, 48), byte(prefix, 40), byte(prefix, 32),
            byte(prefix, 24), byte(prefix, 16), byte(prefix, 8), byte(prefix, 0),
            byte(counter, 56), byte(counter, 48), byte(counter, 40), byte(counter, 32),
            byte(counter, 24), byte(counter, 16), byte(counter, 8), byte(counter, 0)
        ))
    }

    @inline(__always)
    private static func byte(_ value: UInt64, _ shift: UInt64) -> UInt8 {
        UInt8(truncatingIfNeeded: value >> shift)
    }
}
