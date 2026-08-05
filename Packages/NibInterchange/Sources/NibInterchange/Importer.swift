import Foundation
import NibCore

/// Anything that turns someone else's export into ours.
///
/// Implementations are `static` functions over `Data`, returning value types. No I/O, no UI,
/// no clock. The entire importer suite therefore runs against the fixture corpus in
/// milliseconds, which is what makes it practical to drive development off 30+ real-world
/// collections rather than one hand-written example.
public protocol Importer {
    /// Cheap sniff — must not throw, and must not fully parse.
    static func canHandle(_ data: Data, filename: String) -> Bool
    static func importing(_ data: Data) throws -> ImportResult
}

public struct ImportResult: Sendable {
    public var collectionName: String
    public var requestCount: Int
    public var environmentCount: Int

    /// INVARIANT: an import never silently drops anything.
    ///
    /// Every construct we recognise but cannot execute — Postman pre-request and test
    /// scripts, OAuth 2.0 configuration, proxy settings, unsupported auth schemes — is
    /// recorded here *and* preserved verbatim in the request so it round-trips.
    ///
    /// This is the difference between "we don't support scripts" and "your collection
    /// quietly stopped working". The import report sheet is built straight from this array.
    public var diagnostics: [ImportDiagnostic]

    public init(
        collectionName: String,
        requestCount: Int,
        environmentCount: Int = 0,
        diagnostics: [ImportDiagnostic] = []
    ) {
        self.collectionName = collectionName
        self.requestCount = requestCount
        self.environmentCount = environmentCount
        self.diagnostics = diagnostics
    }
}

public struct ImportDiagnostic: Sendable, Hashable {
    public enum Severity: Sendable, Hashable {
        /// Imported and preserved, but Nib will not act on it. The user needs to know.
        case preserved
        /// Imported with a change in behaviour.
        case adjusted
        /// Could not be represented at all. Rare, and always named explicitly.
        case dropped
    }

    public var severity: Severity
    /// Human-facing path, e.g. `Users / Create user`. Lets the report sheet name the exact
    /// request rather than saying "some requests".
    public var path: String
    public var message: String

    public init(severity: Severity, path: String, message: String) {
        self.severity = severity
        self.path = path
        self.message = message
    }
}

public enum ImportError: Error, Sendable {
    case unrecognisedFormat
    case malformed(reason: String)
    /// A schema version we know about but have not implemented.
    case unsupportedVersion(String)
}
