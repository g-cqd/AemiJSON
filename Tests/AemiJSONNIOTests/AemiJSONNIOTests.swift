import NIOCore
import Testing

@testable import AemiJSONNIO

// The swift-nio bridge: zero-copy `ByteBuffer` parse and `ByteBuffer` write sink. Built only under
// AEMIJSON_NIO; AemiJSONNIO re-exports AemiJSONCore, so JSON/JSONValue/AemiJSON are available here directly.

@Test func parsesByteBufferAndLeavesReaderIndex() throws {
    var buffer = ByteBuffer()
    buffer.writeString(#"{"a":1,"b":[true,null,"x"],"n":3.5}"#)
    let doc = try AemiJSON.parse(buffer)
    #expect(doc.root.a.int == 1)
    #expect(doc.root.b[index: 2].string == "x")
    #expect(doc.root.n.double == 3.5)
    #expect(buffer.readerIndex == 0)  // parsing borrows; it does not consume the buffer
    #expect(buffer.readableBytes == 35)
}

@Test func parseBorrowsAndSurvivesCallerMutation() throws {
    var buffer = ByteBuffer(string: #"{"k":"value"}"#)
    let doc = try AemiJSON.parse(buffer)
    buffer.clear()  // CoW: the document keeps its own stable copy
    buffer.writeString("garbage")
    #expect(doc.root.k.string == "value")
}

@Test func writeJSONValueRoundTrips() throws {
    let value = JSONValue.object(["z": .int(1), "a": .array([.bool(true), .null]), "m": .string("hi")])
    var out = ByteBuffer()
    try out.writeJSON(value, options: JSONEncodingOptions(keyOrder: .sorted))
    #expect(out.getString(at: 0, length: out.readableBytes) == #"{"a":[true,null],"m":"hi","z":1}"#)
    #expect(try JSONValue(AemiJSON.parse(out).root) == value)
}

@Test func writeJSONFromCursorSortedAndPretty() throws {
    let doc = try AemiJSON.parse(ByteBuffer(string: #"{"b":2,"a":1}"#))
    var compact = ByteBuffer()
    try compact.writeJSON(doc.root, options: JSONEncodingOptions(keyOrder: .sorted))
    #expect(compact.getString(at: 0, length: compact.readableBytes) == #"{"a":1,"b":2}"#)

    var pretty = ByteBuffer()
    try pretty.writeJSON(doc.root, options: JSONEncodingOptions(keyOrder: .sorted, prettyPrinted: true))
    #expect(pretty.getString(at: 0, length: pretty.readableBytes) == "{\n  \"a\" : 1,\n  \"b\" : 2\n}")
}

@Test func parseRejectsMalformedByteBuffer() {
    #expect(throws: JSONError.self) { _ = try AemiJSON.parse(ByteBuffer(string: "{bad")) }
    #expect(throws: JSONError.self) { _ = try AemiJSON.parse(ByteBuffer()) }  // empty
}

@Test func parsesByteBufferSliceAtNonZeroReaderIndex() throws {
    // Only the readable region is parsed — bytes before the reader index are ignored.
    var buffer = ByteBuffer(string: #"XXXX{"v":42}"#)
    buffer.moveReaderIndex(forwardBy: 4)  // skip "XXXX"
    let doc = try AemiJSON.parse(buffer)
    #expect(doc.root.v.int == 42)
}
