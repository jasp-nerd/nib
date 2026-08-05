import Foundation
import NibCore

/// Postman environment and globals exports.
///
/// A separate file type from a collection, told apart by having `values` and
/// `_postman_variable_scope` and no `info.schema`.
public enum PostmanEnvironmentImporter {

    public struct Imported: Sendable {
        public var environment: NibCore.Environment
        public var diagnostics: [ImportDiagnostic]
    }

    public static func looksLikePostmanEnvironment(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        // `values` alone is not enough -- plenty of JSON has a `values` key. Require the absence of a
        // collection's `info.schema` too.
        guard object["values"] is [Any] else { return false }
        if let info = object["info"] as? [String: Any], info["schema"] != nil { return false }
        return true
    }

    public static func importEnvironment(_ data: Data) throws -> Imported {
        let parsed: Postman.EnvironmentExport
        do {
            parsed = try JSONDecoder().decode(Postman.EnvironmentExport.self, from: data)
        } catch {
            throw ImportError.malformed(reason: "Not a readable Postman environment.")
        }

        var diagnostics: [ImportDiagnostic] = []

        // A globals export has no name. "Globals" is what Postman calls it in the UI.
        let name = parsed.name ?? (parsed.scope == "globals" ? "Globals" : "Imported environment")

        var secretCount = 0
        let variables = parsed.values.compactMap { value -> EnvironmentVariable? in
            guard !value.key.isEmpty else { return nil }
            if value.isSecret { secretCount += 1 }
            return EnvironmentVariable(
                key: value.key,
                value: value.value,
                secret: value.isSecret,
                enabled: value.enabled != false)
        }

        if secretCount > 0 {
            // Worth saying out loud: the values are kept, but they go to the Keychain rather than into
            // the file, so a colleague cloning the repo will be prompted rather than silently sending
            // an empty token.
            diagnostics.append(
                ImportDiagnostic(
                    severity: .adjusted, path: name,
                    message:
                        "\(secretCount) secret value(s) will be stored in your Keychain, not in the "
                        + "collection folder. They are never written to disk."))
        }

        return Imported(
            environment: NibCore.Environment(name: name, variables: variables),
            diagnostics: diagnostics)
    }
}
