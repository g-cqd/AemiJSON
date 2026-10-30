import AemiJSONCore
import AemiJSONRPC
import Testing

private func parse(_ text: String) throws(JSONRPCError) -> JSONRPCMessage {
    try JSONRPCMessage(parsing: Array(text.utf8))
}

private func refusal(_ text: String) -> JSONRPCError? {
    do {
        _ = try parse(text)
        return nil
    } catch { return error }
}

@Suite struct JSONRPCMessageTests {
    @Test func parsesARequestWithANumberID() throws {
        guard case .request(let request) = try parse(#"{"jsonrpc":"2.0","id":7,"method":"a","params":{"x":1}}"#) else {
            Issue.record("not a request")
            return
        }
        #expect(request.id == .number(7))
        #expect(request.method == "a")
        #expect(request.params?["x"].int == 1)
    }

    @Test func parsesARequestWithAStringIDAndNoParams() throws {
        guard case .request(let request) = try parse(#"{"jsonrpc":"2.0","id":"sk-1","method":"b"}"#) else {
            Issue.record("not a request")
            return
        }
        #expect(request.id == .string("sk-1"))
        #expect(request.params == nil)
    }

    @Test func parsesANotification() throws {
        guard case .notification(let note) = try parse(#"{"jsonrpc":"2.0","method":"n","params":[1]}"#) else {
            Issue.record("not a notification")
            return
        }
        #expect(note.method == "n")
        #expect(note.params?[index: 0].int == 1)
    }

    @Test func parsesAResult() throws {
        guard case .response(let id, let result) = try parse(#"{"jsonrpc":"2.0","id":3,"result":{"ok":true}}"#) else {
            Issue.record("not a response")
            return
        }
        #expect(id == .number(3))
        #expect(try result.get()["ok"].bool == true)
    }

    @Test func parsesANullResult() throws {
        guard case .response(_, let result) = try parse(#"{"jsonrpc":"2.0","id":3,"result":null}"#) else {
            Issue.record("not a response")
            return
        }
        #expect(try result.get().isNull)
    }

    @Test func parsesAnErrorWithDataAndANullID() throws {
        let text = #"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"bad","data":{"at":4}}}"#
        guard case .response(let id, let result) = try parse(text) else {
            Issue.record("not a response")
            return
        }
        #expect(id == nil)
        let expected = JSONRPCError(code: JSONRPCError.parseError, message: "bad", data: ["at": 4])
        #expect(throws: expected) { try result.get() }
    }

    @Test func refusesWhatIsNotJSON() {
        #expect(refusal("{oops")?.code == JSONRPCError.parseError)
    }

    @Test(arguments: [
        #"[1]"#,
        #"{"id":1,"method":"a"}"#,
        #"{"jsonrpc":"1.0","id":1,"method":"a"}"#,
        #"{"jsonrpc":"2.0","id":1,"method":3}"#,
        #"{"jsonrpc":"2.0","id":{},"method":"a"}"#,
        #"{"jsonrpc":"2.0","id":1.5,"method":"a"}"#,
        #"{"jsonrpc":"2.0","id":1,"method":"a","params":3}"#,
        #"{"jsonrpc":"2.0","id":1}"#,
        #"{"jsonrpc":"2.0","id":1,"result":1,"error":{"code":1,"message":"m"}}"#,
        #"{"jsonrpc":"2.0","id":1,"error":{"message":"m"}}"#
    ])
    func refusesAnInvalidMessage(text: String) {
        #expect(refusal(text)?.code == JSONRPCError.invalidRequest)
    }

    @Test func keepsTheIDOfAnInvalidRequest() {
        #expect(refusal(#"{"jsonrpc":"2.0","id":"q","method":3}"#)?.data == ["id": "q"])
    }
}

@Suite struct JSONRPCWritingTests {
    private func reparse(_ bytes: [UInt8]) throws -> JSONRPCMessage { try JSONRPCMessage(parsing: bytes) }

    @Test func writesARequest() throws {
        let bytes = JSONRPC.request(id: .number(4), method: "m", params: ["k": "v"])
        guard case .request(let request) = try reparse(bytes) else {
            Issue.record("not a request")
            return
        }
        #expect(request.id == .number(4))
        #expect(request.params?["k"].string == "v")
    }

    @Test func writesANotificationWithoutParams() throws {
        let bytes = JSONRPC.notification(method: "n")
        #expect(String(decoding: bytes, as: UTF8.self) == #"{"jsonrpc":"2.0","method":"n"}"#)
    }

    @Test func writesAResultForAStringID() throws {
        let bytes = JSONRPC.response(id: .string("a\"b"), result: .null)
        #expect(String(decoding: bytes, as: UTF8.self) == #"{"jsonrpc":"2.0","id":"a\"b","result":null}"#)
    }

    @Test func writesAnErrorForANullID() throws {
        let error = JSONRPCError(code: JSONRPCError.methodNotFound, message: "no", data: [1])
        let bytes = JSONRPC.response(id: nil, error: error)
        guard case .response(let id, let result) = try reparse(bytes) else {
            Issue.record("not a response")
            return
        }
        #expect(id == nil)
        #expect(throws: error) { try result.get() }
    }

    @Test func reservedCodes() {
        #expect(JSONRPCError.parseError == -32700)
        #expect(JSONRPCError.invalidRequest == -32600)
        #expect(JSONRPCError.methodNotFound == -32601)
        #expect(JSONRPCError.invalidParams == -32602)
        #expect(JSONRPCError.internalError == -32603)
    }
}
