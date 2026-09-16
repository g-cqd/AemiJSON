/// Relative JSON Pointer (IETF draft): a non-negative integer of levels to ascend,
/// an optional `+N`/`-N` array-index adjustment, then either `#` (yield the key or
/// index name) or a JSON Pointer to follow. Resolved against a base location.
public struct RelativeJSONPointer: Sendable, Equatable {
    public let up: Int
    public let indexAdjustment: Int
    public let yieldsKeyOrIndex: Bool  // trailing '#'
    public let pointer: JSONPointer?  // trailing JSON Pointer (nil when '#')

    public init(_ string: String) throws(JSONPointerError) {
        let chars = Array(string)
        var i = 0

        guard i < chars.count, chars[i].isNumber else { throw JSONPointerError.invalidSyntax }
        var digits = ""
        while i < chars.count, chars[i].isNumber {
            digits.append(chars[i])
            i += 1
        }
        // no leading zeros (except "0")
        guard let levels = Int(digits), digits == "0" || digits.first != "0" else {
            throw JSONPointerError.invalidSyntax
        }
        up = levels

        var adjust = 0
        if i < chars.count, chars[i] == "+" || chars[i] == "-" {
            let sign = chars[i] == "-" ? -1 : 1
            i += 1
            var adjustDigits = ""
            while i < chars.count, chars[i].isNumber {
                adjustDigits.append(chars[i])
                i += 1
            }
            guard let magnitude = Int(adjustDigits) else { throw JSONPointerError.invalidSyntax }
            adjust = sign * magnitude
        }
        indexAdjustment = adjust

        if i < chars.count, chars[i] == "#" {
            i += 1
            guard i == chars.count else { throw JSONPointerError.invalidSyntax }
            yieldsKeyOrIndex = true
            pointer = nil
        } else {
            yieldsKeyOrIndex = false
            let remainder = String(chars[i...])
            pointer = remainder.isEmpty ? JSONPointer(tokens: []) : try JSONPointer(remainder)
        }
    }

    /// Resolve against `document`, starting from the `base` location.
    public func resolve(from base: JSONPointer, in document: JSONValue) throws(JSONPointerError) -> JSONValue {
        var tokens = base.tokens
        guard tokens.count >= up else { throw JSONPointerError.notFound }
        tokens.removeLast(up)

        if indexAdjustment != 0 {
            guard let last = tokens.last, let index = Int(last) else { throw JSONPointerError.notFound }
            let adjusted = index + indexAdjustment
            guard adjusted >= 0 else { throw JSONPointerError.notFound }
            tokens[tokens.count - 1] = String(adjusted)
        }

        if yieldsKeyOrIndex {
            guard let last = tokens.last else { throw JSONPointerError.notFound }
            if let index = Int(last) { return .number(Double(index)) }
            return .string(last)
        }

        let combined = JSONPointer(tokens: tokens + (pointer?.tokens ?? []))
        guard let value = document.value(at: combined) else { throw JSONPointerError.notFound }
        return value
    }
}
