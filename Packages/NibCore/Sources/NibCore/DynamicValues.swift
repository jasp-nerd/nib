import Foundation

/// Generator for Postman's `{{$dynamic}}` variables.
///
/// These are produced at send time rather than stored, so they are injected rather than
/// hardcoded — that keeps `VariableResolver` a pure function and makes its tests
/// deterministic. Anything we do not recognise returns `nil` and is passed through
/// literally, which is the honest behaviour: we would rather send `{{$randomBankAccount}}`
/// verbatim and have the user notice than silently substitute an empty string.
public struct DynamicValues: Sendable {
    public let generate: @Sendable (_ name: String) -> String?

    public init(generate: @escaping @Sendable (_ name: String) -> String?) {
        self.generate = generate
    }

    /// The names we actually support. Everything else in Postman's (very long) dynamic
    /// variable list passes through untouched.
    public static let supportedNames: Set<String> = [
        "$guid", "$randomUUID", "$timestamp", "$isoTimestamp", "$randomInt",
    ]

    public static let live = DynamicValues { name in
        switch name {
        case "$guid", "$randomUUID":
            UUID().uuidString.lowercased()
        case "$timestamp":
            String(Int(Date().timeIntervalSince1970))
        case "$isoTimestamp":
            ISO8601DateFormatter().string(from: Date())
        case "$randomInt":
            String(Int.random(in: 0...1000))
        default:
            nil
        }
    }

    /// Fixed values, for tests and for the "preview resolved URL" affordance where we do
    /// not want the preview to change on every keystroke.
    public static func fixed(
        uuid: String = "00000000-0000-0000-0000-000000000000",
        timestamp: Int = 0,
        isoTimestamp: String = "1970-01-01T00:00:00Z",
        randomInt: Int = 42
    ) -> DynamicValues {
        DynamicValues { name in
            switch name {
            case "$guid", "$randomUUID": uuid
            case "$timestamp": String(timestamp)
            case "$isoTimestamp": isoTimestamp
            case "$randomInt": String(randomInt)
            default: nil
            }
        }
    }

    /// Resolves nothing. Used when we want to report every dynamic variable as unresolved.
    public static let none = DynamicValues { _ in nil }
}
