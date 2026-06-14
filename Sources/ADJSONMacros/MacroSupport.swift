import SwiftDiagnostics
import SwiftSyntax

// Shared helpers for the ADJSON macros (`@JSONCodable`, `@Schemable`).

// Integer scalar type names. Mapped to the fast integer path (`@JSONCodable`) and to JSON
// `"integer"` (`@Schemable`).
let integerTypes: Set<String> = [
    "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
]

// True when the struct declares a custom `CodingKeys` enum. Both macros skip such types: the
// JSON key names would no longer match the property names they assume.
func declaresCodingKeys(_ decl: StructDeclSyntax) -> Bool {
    decl.memberBlock.members.contains { member in
        member.decl.as(EnumDeclSyntax.self)?.name.text == "CodingKeys"
    }
}

// A binding is computed when it exposes a getter; `willSet`/`didSet` observers keep it stored.
func isComputed(_ accessor: AccessorBlockSyntax?) -> Bool {
    guard let accessor else { return false }
    switch accessor.accessors {
    case .getter:
        return true
    case .accessors(let list):
        return list.contains { $0.accessorSpecifier.tokenKind == .keyword(.get) }
    }
}

// A `.warning` anchored on the macro attribute, in the shared "ADJSON" diagnostic domain. Both
// macros degrade gracefully (return no extension) rather than erroring, so warnings — not errors —
// are emitted.
func note(_ node: AttributeSyntax, _ id: String, _ message: String) -> Diagnostic {
    Diagnostic(
        node: node,
        message: SimpleDiagnostic(
            message: message, diagnosticID: MessageID(domain: "ADJSON", id: id), severity: .warning))
}

struct SimpleDiagnostic: DiagnosticMessage {
    let message: String
    let diagnosticID: MessageID
    let severity: DiagnosticSeverity
}
