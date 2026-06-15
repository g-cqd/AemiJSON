import ADJSON

// Same shape as the plain Codable `User`/`Profile`, but with the macro-generated fast paths:
// @JSONCodable drives the coder fast path, @Schemable supplies a compile-time JSON Schema. The
// bench measures the macro-generated code directly for both.

@JSONCodable
@Schemable
struct MacroProfile: Codable, Equatable {
    var bio: String
    var company: String?
    var publicRepos: Int
    var location: String?
}

@JSONCodable
@Schemable
struct MacroUser: Codable, Equatable {
    var id: Int
    var login: String
    var name: String?
    var email: String?
    var followers: Int
    var following: Int
    var isAdmin: Bool
    var score: Double
    var tags: [String]
    var profile: MacroProfile
}
