import Foundation

// MARK: - Codable model (keyed-object-heavy, the case people complain about)

struct Profile: Codable, Equatable {
    var bio: String
    var company: String?
    var publicRepos: Int
    var location: String?
}

struct User: Codable, Equatable {
    var id: Int
    var login: String
    var name: String?
    var email: String?
    var followers: Int
    var following: Int
    var isAdmin: Bool
    var score: Double
    var tags: [String]
    var profile: Profile
}

// MARK: - Untyped value tree (for the JSONSerialization comparison)

indirect enum JSONValue {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Deterministic generator (no Foundation RNG variance, reproducible)

struct LCG {
    var s: UInt64
    @inline(__always) mutating func next() -> UInt64 {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return s
    }
    @inline(__always) mutating func int(_ n: Int) -> Int {
        precondition(n > 0)
        return Int(next() >> 33) % n
    }
}

private let words = [
    "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel",
    "india", "juliet", "kilo", "lima", "mike", "november", "oscar", "papa",
    "quebec", "romeo", "sierra", "tango", "uniform", "victor", "whiskey", "xray",
]

func makeUsers(_ count: Int) -> [User] {
    var r = LCG(s: 0x1234_5678_9abc_def0)
    func word() -> String { words[r.int(words.count)] }
    func sentence(_ k: Int) -> String {
        var parts: [String] = []
        for _ in 0..<k { parts.append(word()) }
        return parts.joined(separator: " ")
    }
    var users: [User] = []
    users.reserveCapacity(count)
    for k in 0..<count {
        let tagN = r.int(5)
        var tags: [String] = []
        for _ in 0..<tagN { tags.append(word()) }
        users.append(
            User(
                id: k,
                login: word() + String(k),
                name: r.int(10) > 2 ? sentence(2) : nil,
                email: r.int(10) > 3 ? word() + "@" + word() + ".com" : nil,
                followers: r.int(100_000),
                following: r.int(2_000),
                isAdmin: r.int(10) == 0,
                score: Double(r.int(1_000_000)) / 1000.0,
                tags: tags,
                profile: Profile(
                    bio: sentence(6),
                    company: r.int(10) > 4 ? word() : nil,
                    publicRepos: r.int(500),
                    location: r.int(10) > 3 ? word() : nil
                )
            ))
    }
    return users
}

func makeDoubles(_ n: Int) -> [Double] {
    var r = LCG(s: 0x9e37_79b9_7f4a_7c15)
    var a: [Double] = []
    a.reserveCapacity(n)
    for _ in 0..<n { a.append(Double(r.int(1_000_000_000)) / 997.0) }
    return a
}
