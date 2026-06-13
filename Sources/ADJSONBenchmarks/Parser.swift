import Foundation

// Minimal targeted byte parser: recursive descent over raw UTF-8 bytes,
// byte-wise key matching (no String key allocs, no per-object Dictionary),
// direct field binding. Represents the realistic ceiling a generated decoder hits.
struct JSONByteParser {
    let p: UnsafePointer<UInt8>
    let n: Int
    var i: Int = 0

    init(_ p: UnsafePointer<UInt8>, _ n: Int) {
        self.p = p
        self.n = n
    }

    @inline(__always) mutating func skipWS() {
        while i < n {
            let c = p[i]
            if c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 { i += 1 } else { break }
        }
    }

    @inline(__always) mutating func expect(_ b: UInt8) {
        if i < n && p[i] == b { i += 1 } else { fatalError("expected \(b) at \(i)") }
    }

    // Returns byte range of string contents (between quotes), assumes p[i] == '"'.
    @inline(__always) mutating func parseStringRange() -> (start: Int, len: Int, esc: Bool) {
        i += 1  // opening quote
        let start = i
        var esc = false
        while i < n {
            let c = p[i]
            if c == 0x22 {
                let len = i - start
                i += 1
                return (start, len, esc)
            }
            if c == 0x5C {
                esc = true
                i += 2
                continue
            }
            i += 1
        }
        fatalError("unterminated string")
    }

    @inline(__always) mutating func parseString() -> String {
        let (s, len, esc) = parseStringRange()
        if !esc {
            return String(decoding: UnsafeBufferPointer(start: p + s, count: len), as: UTF8.self)
        }
        return unescape(start: s, len: len)
    }

    mutating func unescape(start: Int, len: Int) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(len)
        var j = start
        let end = start + len
        while j < end {
            let c = p[j]
            if c != 0x5C {
                out.append(c)
                j += 1
                continue
            }
            j += 1
            let e = p[j]
            j += 1
            switch e {
            case 0x22: out.append(0x22)
            case 0x5C: out.append(0x5C)
            case 0x2F: out.append(0x2F)
            case 0x6E: out.append(0x0A)
            case 0x74: out.append(0x09)
            case 0x72: out.append(0x0D)
            case 0x62: out.append(0x08)
            case 0x66: out.append(0x0C)
            case 0x75:
                var u: UInt32 = 0
                for _ in 0..<4 {
                    u = (u << 4) | UInt32(hexVal(p[j]))
                    j += 1
                }
                if let scalar = Unicode.Scalar(u) {
                    out.append(contentsOf: Array(String(scalar).utf8))
                }
            default: out.append(e)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    @inline(__always) func hexVal(_ b: UInt8) -> UInt8 {
        if b >= 0x30 && b <= 0x39 { return b - 0x30 }
        if b >= 0x61 && b <= 0x66 { return b - 0x61 + 10 }
        return b - 0x41 + 10
    }

    @inline(__always) mutating func parseInt() -> Int {
        var neg = false
        if p[i] == 0x2D {
            neg = true
            i += 1
        }
        var v = 0
        while i < n {
            let c = p[i]
            if c >= 0x30 && c <= 0x39 {
                v = v * 10 + Int(c - 0x30)
                i += 1
            } else {
                break
            }
        }
        return neg ? -v : v
    }

    @inline(__always) mutating func parseDouble() -> Double {
        let start = i
        while i < n {
            let c = p[i]
            if (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x2B || c == 0x2E || c == 0x65 || c == 0x45 {
                i += 1
            } else {
                break
            }
        }
        let cptr = UnsafeRawPointer(p + start).assumingMemoryBound(to: CChar.self)
        return strtod(cptr, nil)
    }

    @inline(__always) func keyEq(_ start: Int, _ len: Int, _ lit: StaticString) -> Bool {
        len == lit.utf8CodeUnitCount && memcmp(p + start, lit.utf8Start, len) == 0
    }

    // MARK: typed parsers

    mutating func parseUsers() -> [User] {
        var out: [User] = []
        skipWS()
        expect(0x5B)
        skipWS()
        if p[i] == 0x5D {
            i += 1
            return out
        }
        while true {
            out.append(parseUser())
            skipWS()
            let c = p[i]
            if c == 0x2C {
                i += 1
                skipWS()
                continue
            }
            if c == 0x5D {
                i += 1
                break
            }
            fatalError("bad array")
        }
        return out
    }

    mutating func parseUser() -> User {
        var id = 0, followers = 0, following = 0
        var isAdmin = false
        var score = 0.0
        var login = ""
        var name: String? = nil
        var email: String? = nil
        var tags: [String] = []
        var profile = Profile(bio: "", company: nil, publicRepos: 0, location: nil)

        skipWS()
        expect(0x7B)
        skipWS()
        if p[i] == 0x7D {
            i += 1
            return User(
                id: id, login: login, name: name, email: email, followers: followers, following: following,
                isAdmin: isAdmin, score: score, tags: tags, profile: profile)
        }
        while true {
            skipWS()
            let (ks, kl, _) = parseStringRange()
            skipWS()
            expect(0x3A)
            skipWS()
            if keyEq(ks, kl, "id") {
                id = parseInt()
            } else if keyEq(ks, kl, "login") {
                login = parseString()
            } else if keyEq(ks, kl, "name") {
                if p[i] == 0x6E { i += 4 } else { name = parseString() }
            } else if keyEq(ks, kl, "email") {
                if p[i] == 0x6E { i += 4 } else { email = parseString() }
            } else if keyEq(ks, kl, "followers") {
                followers = parseInt()
            } else if keyEq(ks, kl, "following") {
                following = parseInt()
            } else if keyEq(ks, kl, "isAdmin") {
                isAdmin = parseBool()
            } else if keyEq(ks, kl, "score") {
                score = parseDouble()
            } else if keyEq(ks, kl, "tags") {
                tags = parseStringArray()
            } else if keyEq(ks, kl, "profile") {
                profile = parseProfile()
            } else {
                skipValue()
            }
            skipWS()
            let c = p[i]
            if c == 0x2C {
                i += 1
                continue
            }
            if c == 0x7D {
                i += 1
                break
            }
            fatalError("bad object")
        }
        return User(
            id: id, login: login, name: name, email: email, followers: followers, following: following,
            isAdmin: isAdmin, score: score, tags: tags, profile: profile)
    }

    mutating func parseProfile() -> Profile {
        var bio = ""
        var company: String? = nil
        var publicRepos = 0
        var location: String? = nil
        skipWS()
        expect(0x7B)
        skipWS()
        if p[i] == 0x7D {
            i += 1
            return Profile(bio: bio, company: company, publicRepos: publicRepos, location: location)
        }
        while true {
            skipWS()
            let (ks, kl, _) = parseStringRange()
            skipWS()
            expect(0x3A)
            skipWS()
            if keyEq(ks, kl, "bio") {
                bio = parseString()
            } else if keyEq(ks, kl, "company") {
                if p[i] == 0x6E { i += 4 } else { company = parseString() }
            } else if keyEq(ks, kl, "publicRepos") {
                publicRepos = parseInt()
            } else if keyEq(ks, kl, "location") {
                if p[i] == 0x6E { i += 4 } else { location = parseString() }
            } else {
                skipValue()
            }
            skipWS()
            let c = p[i]
            if c == 0x2C {
                i += 1
                continue
            }
            if c == 0x7D {
                i += 1
                break
            }
            fatalError("bad object")
        }
        return Profile(bio: bio, company: company, publicRepos: publicRepos, location: location)
    }

    mutating func parseBool() -> Bool {
        if p[i] == 0x74 {
            i += 4
            return true
        } else {
            i += 5
            return false
        }
    }

    mutating func parseStringArray() -> [String] {
        var out: [String] = []
        skipWS()
        expect(0x5B)
        skipWS()
        if p[i] == 0x5D {
            i += 1
            return out
        }
        while true {
            skipWS()
            out.append(parseString())
            skipWS()
            let c = p[i]
            if c == 0x2C {
                i += 1
                continue
            }
            if c == 0x5D {
                i += 1
                break
            }
            fatalError("bad string array")
        }
        return out
    }

    mutating func parseDoubleArray() -> [Double] {
        var out: [Double] = []
        skipWS()
        expect(0x5B)
        skipWS()
        if p[i] == 0x5D {
            i += 1
            return out
        }
        while true {
            skipWS()
            out.append(parseDouble())
            skipWS()
            let c = p[i]
            if c == 0x2C {
                i += 1
                continue
            }
            if c == 0x5D {
                i += 1
                break
            }
            fatalError("bad double array")
        }
        return out
    }

    mutating func skipValue() {
        skipWS()
        let c = p[i]
        switch c {
        case 0x22: _ = parseStringRange()
        case 0x7B:
            i += 1
            skipWS()
            if p[i] == 0x7D {
                i += 1
                return
            }
            while true {
                skipWS()
                _ = parseStringRange()
                skipWS()
                expect(0x3A)
                skipValue()
                skipWS()
                let d = p[i]
                if d == 0x2C {
                    i += 1
                    continue
                }
                if d == 0x7D {
                    i += 1
                    break
                }
                fatalError()
            }
        case 0x5B:
            i += 1
            skipWS()
            if p[i] == 0x5D {
                i += 1
                return
            }
            while true {
                skipValue()
                skipWS()
                let d = p[i]
                if d == 0x2C {
                    i += 1
                    continue
                }
                if d == 0x5D {
                    i += 1
                    break
                }
                fatalError()
            }
        case 0x74: i += 4
        case 0x66: i += 5
        case 0x6E: i += 4
        default: _ = parseDouble()
        }
    }

    // MARK: untyped tree

    mutating func parseValue() -> JSONValue {
        skipWS()
        let c = p[i]
        switch c {
        case 0x22: return .string(parseString())
        case 0x7B: return parseObject()
        case 0x5B: return parseArray()
        case 0x74:
            i += 4
            return .bool(true)
        case 0x66:
            i += 5
            return .bool(false)
        case 0x6E:
            i += 4
            return .null
        default: return .number(parseDouble())
        }
    }

    mutating func parseObject() -> JSONValue {
        var dict: [String: JSONValue] = [:]
        i += 1
        skipWS()
        if p[i] == 0x7D {
            i += 1
            return .object(dict)
        }
        while true {
            skipWS()
            let key = parseString()
            skipWS()
            expect(0x3A)
            dict[key] = parseValue()
            skipWS()
            let c = p[i]
            if c == 0x2C {
                i += 1
                continue
            }
            if c == 0x7D {
                i += 1
                break
            }
            fatalError("bad object")
        }
        return .object(dict)
    }

    mutating func parseArray() -> JSONValue {
        var arr: [JSONValue] = []
        i += 1
        skipWS()
        if p[i] == 0x5D {
            i += 1
            return .array(arr)
        }
        while true {
            arr.append(parseValue())
            skipWS()
            let c = p[i]
            if c == 0x2C {
                i += 1
                continue
            }
            if c == 0x5D {
                i += 1
                break
            }
            fatalError("bad array")
        }
        return .array(arr)
    }
}
