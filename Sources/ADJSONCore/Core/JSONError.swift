/// Errors thrown while scanning malformed or oversized JSON input.
public enum JSONError: Error, Sendable, Equatable {
    case unexpectedEndOfInput
    case unexpectedCharacter(UInt8, at: Int)
    case invalidNumber(at: Int)
    case invalidString(at: Int)
    case depthExceeded(at: Int)
    case trailingData(at: Int)
    case documentTooLarge
    case invalidUTF8(at: Int)
    case duplicateKey(at: Int)
}
