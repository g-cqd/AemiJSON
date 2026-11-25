# Security Policy

## Scope

`AemiJSON` parses untrusted JSON, JSON5, JSON Schema, JSONPath, and JSON-RPC payloads. Parsing enforces strict RFC 8259 validation, explicit nesting depth limits, and bounded allocations without recursion. No network access is performed.

## Supported Versions

Security fixes land on `main` and the latest tagged release (when releases are published). Pin a specific tag or commit revision for reproducible builds.

## Reporting a Vulnerability

Report security issues privately via [GitHub Security Advisories](https://github.com/g-cqd/AemiJSON/security/advisories/new). Do not open public issues with exploit details or sensitive material. Include the commit or version, platform, and a minimal reproduction.
