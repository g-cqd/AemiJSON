import ADJSON

// Hand-written equivalents of what the @JSONCodable macro will generate.
// Used to validate that the fast-path runtime + generic-container dispatch
// reach the hand-rolled ceiling before investing in swift-syntax codegen.

extension Profile: ADJSONFastDecodable, ADJSONFastEncodable {
    static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> Profile {
        Profile(
            bio: try c.string("bio"),
            company: c.stringIfPresent("company"),
            publicRepos: try c.integer("publicRepos", Int.self),
            location: c.stringIfPresent("location")
        )
    }

    func __adjsonEncode(into w: _FastEncodeWriter) throws {
        w.beginObject()
        w.key("bio")
        w.string(bio)
        if let v = company {
            w.comma()
            w.key("company")
            w.string(v)
        }
        w.comma()
        w.key("publicRepos")
        w.integer(publicRepos)
        if let v = location {
            w.comma()
            w.key("location")
            w.string(v)
        }
        w.endObject()
    }
}

extension User: ADJSONFastDecodable, ADJSONFastEncodable {
    static func __adjsonDecode(_ c: _FastDecodeCursor) throws -> User {
        User(
            id: try c.integer("id", Int.self),
            login: try c.string("login"),
            name: c.stringIfPresent("name"),
            email: c.stringIfPresent("email"),
            followers: try c.integer("followers", Int.self),
            following: try c.integer("following", Int.self),
            isAdmin: try c.bool("isAdmin"),
            score: try c.double("score"),
            tags: try c.decode([String].self, "tags"),
            profile: try c.decode(Profile.self, "profile")
        )
    }

    func __adjsonEncode(into w: _FastEncodeWriter) throws {
        w.beginObject()
        w.key("id")
        w.integer(id)
        w.comma()
        w.key("login")
        w.string(login)
        if let v = name {
            w.comma()
            w.key("name")
            w.string(v)
        }
        if let v = email {
            w.comma()
            w.key("email")
            w.string(v)
        }
        w.comma()
        w.key("followers")
        w.integer(followers)
        w.comma()
        w.key("following")
        w.integer(following)
        w.comma()
        w.key("isAdmin")
        w.bool(isAdmin)
        w.comma()
        w.key("score")
        try w.double(score)
        w.comma()
        w.key("tags")
        try w.encode(tags)
        w.comma()
        w.key("profile")
        try w.encode(profile)
        w.endObject()
    }
}
