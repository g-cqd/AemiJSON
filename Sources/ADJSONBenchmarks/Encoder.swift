import Foundation

// Minimal direct-to-buffer encoder: single contiguous [UInt8], no reference tree,
// no value tree, no Dictionary. Numbers formatted straight into the buffer
// (Double via shortest-round-trip description, same as Foundation).
struct MiniEncoder {
    var out: [UInt8] = []

    static func encode(_ users: [User]) -> [UInt8] {
        var e = MiniEncoder()
        e.out.reserveCapacity(users.count * 256)
        e.writeUsers(users)
        return e.out
    }

    @inline(__always) mutating func comma() { out.append(0x2C) }

    @inline(__always) mutating func key(_ s: StaticString) {
        out.append(0x22)
        out.append(contentsOf: UnsafeBufferPointer(start: s.utf8Start, count: s.utf8CodeUnitCount))
        out.append(0x22)
        out.append(0x3A)
    }

    mutating func writeUsers(_ users: [User]) {
        out.append(0x5B)
        var first = true
        for u in users {
            if first { first = false } else { comma() }
            writeUser(u)
        }
        out.append(0x5D)
    }

    mutating func writeUser(_ u: User) {
        out.append(0x7B)
        key("id")
        int(u.id)
        comma()
        key("login")
        str(u.login)
        if let v = u.name {
            comma()
            key("name")
            str(v)
        }
        if let v = u.email {
            comma()
            key("email")
            str(v)
        }
        comma()
        key("followers")
        int(u.followers)
        comma()
        key("following")
        int(u.following)
        comma()
        key("isAdmin")
        bool(u.isAdmin)
        comma()
        key("score")
        dbl(u.score)
        comma()
        key("tags")
        strArray(u.tags)
        comma()
        key("profile")
        writeProfile(u.profile)
        out.append(0x7D)
    }

    mutating func writeProfile(_ pr: Profile) {
        out.append(0x7B)
        key("bio")
        str(pr.bio)
        if let v = pr.company {
            comma()
            key("company")
            str(v)
        }
        comma()
        key("publicRepos")
        int(pr.publicRepos)
        if let v = pr.location {
            comma()
            key("location")
            str(v)
        }
        out.append(0x7D)
    }

    mutating func strArray(_ a: [String]) {
        out.append(0x5B)
        var first = true
        for s in a {
            if first { first = false } else { comma() }
            str(s)
        }
        out.append(0x5D)
    }

    @inline(__always) mutating func bool(_ b: Bool) {
        if b {
            out.append(contentsOf: [0x74, 0x72, 0x75, 0x65])
        } else {
            out.append(contentsOf: [0x66, 0x61, 0x6C, 0x73, 0x65])
        }
    }

    @inline(__always) mutating func int(_ v: Int) {
        if v < 0 {
            out.append(0x2D)
            uint(v.magnitude)
        } else {
            uint(v.magnitude)
        }
    }

    @inline(__always) mutating func uint(_ value: UInt) {
        if value == 0 {
            out.append(0x30)
            return
        }
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 20) { buf in
            var n = value
            var idx = 20
            while n > 0 {
                idx -= 1
                buf[idx] = 0x30 + UInt8(n % 10)
                n /= 10
            }
            out.append(contentsOf: buf[idx..<20])
        }
    }

    @inline(__always) mutating func dbl(_ v: Double) {
        out.append(contentsOf: v.description.utf8)
    }

    mutating func str(_ s: String) {
        out.append(0x22)
        for b in s.utf8 {
            switch b {
            case 0x22:
                out.append(0x5C)
                out.append(0x22)
            case 0x5C:
                out.append(0x5C)
                out.append(0x5C)
            case 0x0A:
                out.append(0x5C)
                out.append(0x6E)
            case 0x0D:
                out.append(0x5C)
                out.append(0x72)
            case 0x09:
                out.append(0x5C)
                out.append(0x74)
            case 0x08:
                out.append(0x5C)
                out.append(0x62)
            case 0x0C:
                out.append(0x5C)
                out.append(0x66)
            case 0..<0x20:
                out.append(contentsOf: [0x5C, 0x75, 0x30, 0x30])
                out.append(hexDigit(b >> 4))
                out.append(hexDigit(b & 0xF))
            default: out.append(b)
            }
        }
        out.append(0x22)
    }

    @inline(__always) func hexDigit(_ v: UInt8) -> UInt8 {
        v < 10 ? 0x30 + v : 0x61 + (v - 10)
    }
}
