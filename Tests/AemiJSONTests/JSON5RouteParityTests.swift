import Testing

@testable import AemiJSON

// The tape parser, the pull reader and the push reader are three scanners for one JSON5 grammar. Rather
// than spot-check the pieces a fix touched, feed all three every short document over an alphabet built from
// the tokens those fixes are about, and demand one verdict and one value. The push reader runs one byte at a
// time and in one chunk, so every multi-byte sequence is cut at every byte.
struct JSON5RouteParityTests {
    private static let alphabet: [String] = [
        "{", "}", "[", "]", ",", ":", "a", "0", "1", ".", "-", "'", "/", "*", "\n", " ", "\u{A0}", "\u{2028}",
        "\u{3000}"
    ]

    private static let routes: [ReadRoute] = [.tape, .pull, .push(chunkSize: 1), .push(chunkSize: 1 << 20)]

    /// Every document of one to `maxLength` tokens over `alphabet`.
    private static func documents(maxLength: Int) -> [String] {
        var all: [String] = []
        var current: [String] = [""]
        for _ in 1 ... maxLength {
            var next: [String] = []
            next.reserveCapacity(current.count * alphabet.count)
            for prefix in current { for token in alphabet { next.append(prefix + token) } }
            all.append(contentsOf: next)
            current = next
        }
        return all
    }

    @Test func everyRouteReadsEveryShortJSON5DocumentTheSameWay() {
        var accepted = 0
        for document in Self.documents(maxLength: 4) {
            let bytes = Array(document.utf8)
            let reference = Self.routes[0].value(of: bytes, options: .json5)
            if reference != nil { accepted += 1 }
            for route in Self.routes.dropFirst() {
                let value = route.value(of: bytes, options: .json5)
                #expect(value == reference, "\(route) disagrees with the tape on \(describe(bytes))")
            }
        }
        // The alphabet reaches real documents, so agreement is not agreement on "everything is invalid".
        #expect(accepted > 100)
    }
}
