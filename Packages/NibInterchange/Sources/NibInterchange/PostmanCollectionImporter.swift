import Foundation
import NibCore

/// Maps a parsed Postman collection onto Nib's model.
///
/// The growth hook: drag in an export and the whole workspace comes across. So the bar is not "it
/// mostly works" — it is that **nothing is silently lost**. Everything Nib cannot execute goes into
/// the request's `preserved` block, round-trips untouched, and is reported as a diagnostic the user
/// actually sees.
// swiftlint:disable:next type_body_length
public enum PostmanCollectionImporter {

    public struct Imported: Sendable {
        public var collection: NibCore.Collection
        public var diagnostics: [ImportDiagnostic]
    }

    /// Does this look like a Postman collection?
    ///
    /// Matches on the schema URL's **path suffix**, because exports carry either `schema.postman.com`
    /// or the older `schema.getpostman.com` and both are in circulation.
    public static func looksLikePostmanCollection(_ data: Data) -> Bool {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let info = object["info"] as? [String: Any]
        else { return false }

        if let schema = info["schema"] as? String,
            schema.hasSuffix("/collection/v2.1.0/collection.json")
                || schema.hasSuffix("/collection/v2.0.0/collection.json")
        {
            return true
        }
        // Some hand-written and older files omit the schema but are otherwise v2-shaped.
        return info["name"] != nil && object["item"] != nil
    }

    public static func importCollection(_ data: Data) throws -> Imported {
        let parsed: Postman.Collection
        do {
            parsed = try JSONDecoder().decode(Postman.Collection.self, from: data)
        } catch {
            throw ImportError.malformed(reason: Self.describe(error))
        }

        var diagnostics: [ImportDiagnostic] = []

        let children = parsed.item.enumerated().flatMap { index, item in
            node(from: item, path: [], fallbackIndex: index, diagnostics: &diagnostics)
        }

        let auth = authSpec(
            from: parsed.auth, path: "collection", diagnostics: &diagnostics)

        // Collection-level scripts are reported once here rather than per request.
        reportScripts(parsed.event, path: parsed.info.name, diagnostics: &diagnostics)

        let collection = NibCore.Collection(
            name: parsed.info.name,
            children: children,
            auth: auth,
            variables: variables(from: parsed.variable)
        )

        return Imported(collection: collection, diagnostics: diagnostics)
    }

    // MARK: - Tree

    /// One Postman item becomes zero or one Nib nodes.
    ///
    /// Returns an array rather than an optional so a malformed item can be skipped without the caller
    /// caring, which is what keeps one bad request from failing a 200-request import.
    private static func node(
        from item: Postman.Item,
        path: [String],
        fallbackIndex: Int,
        diagnostics: inout [ImportDiagnostic]
    ) -> [CollectionNode] {
        // Postman allows an unnamed item. Naming it by position beats dropping it.
        let trimmed = item.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = trimmed.isEmpty ? "Untitled \(fallbackIndex + 1)" : trimmed
        let here = path + [name]

        if let children = item.item {
            let folderAuth = authSpec(
                from: item.auth, path: here.joined(separator: "/"), diagnostics: &diagnostics)
            reportScripts(item.event, path: here.joined(separator: "/"), diagnostics: &diagnostics)

            return [
                .folder(
                    FolderNode(
                        name: name,
                        children: children.enumerated().flatMap { index, child in
                            node(
                                from: child, path: here, fallbackIndex: index,
                                diagnostics: &diagnostics)
                        },
                        auth: folderAuth,
                        variables: variables(from: item.variable)))
            ]
        }

        guard let request = item.request else {
            diagnostics.append(
                ImportDiagnostic(
                    severity: .dropped,
                    path: here.joined(separator: "/"),
                    message: "Item is neither a folder nor a request; skipped."))
            return []
        }

        return [
            .request(
                RequestNode(
                    name: name,
                    spec: spec(
                        from: request, item: item, path: here.joined(separator: "/"),
                        diagnostics: &diagnostics)))
        ]
    }

    // MARK: - Request

    private static func spec(
        from request: Postman.Request,
        item: Postman.Item,
        path: String,
        diagnostics: inout [ImportDiagnostic]
    ) -> HTTPRequestSpec {
        var spec = HTTPRequestSpec()
        spec.method = HTTPMethod(request.method ?? "GET")

        // `raw` is preferred over the component form so `{{variables}}` survive exactly as typed.
        spec.url = request.url?.reconstructed ?? ""
        if spec.url.isEmpty {
            diagnostics.append(
                ImportDiagnostic(
                    severity: .adjusted, path: path,
                    message: "Request has no URL; imported empty."))
        }

        spec.headers = (request.header ?? []).map {
            HeaderField(name: $0.key, value: $0.value ?? "", enabled: $0.disabled != true)
        }

        // Query parameters already live in the reconstructed URL, so only *path* variables become
        // params -- adding the query twice would duplicate every one of them.
        spec.params = (request.url?.variable ?? []).compactMap { variable in
            guard let key = variable.key ?? variable.name else { return nil }
            return Param(
                kind: .path, name: key, value: variable.value ?? "",
                enabled: variable.disabled != true)
        }

        spec.auth = authSpec(from: request.auth, path: path, diagnostics: &diagnostics)
        spec.body = bodySpec(from: request.body, path: path, diagnostics: &diagnostics)

        // Postman only sends a body with GET when this is set, and it defaults to pruning.
        if let behaviour = item.protocolProfileBehavior,
            behaviour["disableBodyPruning"]?.boolValue == true
        {
            spec.settings.sendBodyOnGet = true
        }

        // Anything we cannot run is kept, not discarded.
        var preserved: [String: JSONValue] = [:]

        let scripts = (item.event ?? []).filter(\.hasContent)
        if !scripts.isEmpty {
            preserved["postmanEvents"] = eventsValue(scripts)
            let kinds = scripts.compactMap(\.listen).joined(separator: ", ")
            diagnostics.append(
                ImportDiagnostic(
                    severity: .preserved, path: path,
                    message:
                        "\(scripts.count) script(s) (\(kinds)) preserved but not run. "
                        + "Nib does not execute scripts."))
        }

        if let auth = request.auth, !Self.isSupportedAuth(auth.type) {
            preserved["postmanAuth"] = .object(auth.raw)
        }

        if let behaviour = item.protocolProfileBehavior, !behaviour.isEmpty {
            preserved["protocolProfileBehavior"] = .object(behaviour)
        }

        spec.preserved = preserved.isEmpty ? nil : preserved
        return spec
    }

    private static func eventsValue(_ events: [Postman.Event]) -> JSONValue {
        .array(
            events.map { event in
                var object: [String: JSONValue] = [:]
                if let listen = event.listen { object["listen"] = .string(listen) }
                if let lines = event.script?.exec {
                    object["exec"] = .array(lines.map { .string($0) })
                }
                if let type = event.script?.type { object["type"] = .string(type) }
                return .object(object)
            })
    }

    // MARK: - Body

    static func bodySpec(
        from body: Postman.Body?,
        path: String,
        diagnostics: inout [ImportDiagnostic]
    ) -> BodySpec {
        guard let body, body.disabled != true else { return .none }

        switch body.mode {
        case "raw":
            let text = body.raw ?? ""
            guard !text.isEmpty else { return .none }
            // `options.raw.language` is the only signal for how to pretty-print, so use it before
            // falling back to sniffing the content.
            let language =
                BodySpec.RawLanguage(rawValue: body.options?.raw?.language ?? "")
                ?? sniffLanguage(text)
            return .raw(text: text, language: language)

        case "urlencoded":
            let fields = (body.urlencoded ?? []).map {
                Param(
                    name: $0.key ?? "", value: $0.value ?? "",
                    enabled: $0.disabled != true)
            }
            return fields.isEmpty ? .none : .urlEncoded(fields)

        case "formdata":
            let parts = (body.formdata ?? []).map { field -> MultipartPart in
                let content: MultipartPart.Content =
                    field.type == "file"
                    ? .file(path: field.src?.first ?? "")
                    : .text(field.value ?? "")
                return MultipartPart(
                    name: field.key ?? "", content: content,
                    contentType: field.contentType, enabled: field.disabled != true)
            }
            if (body.formdata ?? []).contains(where: { ($0.src?.count ?? 0) > 1 }) {
                diagnostics.append(
                    ImportDiagnostic(
                        severity: .adjusted, path: path,
                        message: "A multi-file form field was reduced to its first file."))
            }
            return parts.isEmpty ? .none : .multipart(parts)

        case "graphql":
            return .graphQL(
                query: body.graphql?.query ?? "",
                variables: body.graphql?.variables ?? "")

        case "file":
            guard let src = body.file?.src, !src.isEmpty else {
                diagnostics.append(
                    ImportDiagnostic(
                        severity: .dropped, path: path,
                        message:
                            "Binary body has no file path — Postman does not include file contents "
                            + "in an export. Re-attach the file."))
                return .none
            }
            return .binary(path: src)

        case nil:
            return .none

        default:
            diagnostics.append(
                ImportDiagnostic(
                    severity: .dropped, path: path,
                    message: "Unsupported body mode “\(body.mode ?? "")”."))
            return .none
        }
    }

    static func sniffLanguage(_ text: String) -> BodySpec.RawLanguage {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            if (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil { return .json }
        }
        if trimmed.hasPrefix("<") { return .xml }
        return .text
    }

    // MARK: - Auth

    static let supportedAuthTypes: Set<String> = [
        "noauth", "bearer", "basic", "apikey", "inherit",
    ]

    static func isSupportedAuth(_ type: String) -> Bool {
        supportedAuthTypes.contains(type)
    }

    static func authSpec(
        from auth: Postman.Auth?,
        path: String,
        diagnostics: inout [ImportDiagnostic]
    ) -> AuthSpec {
        guard let auth else { return .inherit }

        switch auth.type {
        case "noauth":
            return .none

        case "bearer":
            return .bearer(token: auth.parameters["token"] ?? "")

        case "basic":
            return .basic(
                username: auth.parameters["username"] ?? "",
                password: auth.parameters["password"] ?? "")

        case "apikey":
            // Postman's `in` is "header" or "query"; header is the default.
            let placement: AuthSpec.APIKeyPlacement =
                auth.parameters["in"] == "query" ? .query : .header
            return .apiKey(
                name: auth.parameters["key"] ?? "",
                value: auth.parameters["value"] ?? "",
                placement: placement)

        default:
            // Reported, and the raw payload is preserved by the caller.
            diagnostics.append(
                ImportDiagnostic(
                    severity: .preserved, path: path,
                    message:
                        "“\(auth.type)” auth is not supported in v1. The configuration was preserved; "
                        + "set up auth manually to send this request."))
            return .none
        }
    }

    // MARK: - Variables

    static func variables(from source: [Postman.Variable]?) -> [EnvironmentVariable] {
        (source ?? []).compactMap { variable in
            guard let key = variable.key ?? variable.name, !key.isEmpty else { return nil }
            return EnvironmentVariable(
                key: key,
                value: variable.value,
                secret: variable.type == "secret",
                enabled: variable.disabled != true)
        }
    }

    static func reportScripts(
        _ events: [Postman.Event]?,
        path: String,
        diagnostics: inout [ImportDiagnostic]
    ) {
        let scripts = (events ?? []).filter(\.hasContent)
        guard !scripts.isEmpty else { return }
        diagnostics.append(
            ImportDiagnostic(
                severity: .preserved, path: path,
                message:
                    "\(scripts.count) script(s) at this level preserved but not run."))
    }

    /// Turn a `DecodingError` into something a user can act on.
    static func describe(_ error: any Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }

        func pathDescription(_ context: DecodingError.Context) -> String {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? "the top level" : path
        }

        switch decoding {
        case .keyNotFound(let key, let context):
            return "Missing “\(key.stringValue)” at \(pathDescription(context))."
        case .typeMismatch(_, let context):
            return "Unexpected type at \(pathDescription(context)): \(context.debugDescription)"
        case .valueNotFound(_, let context):
            return "Missing value at \(pathDescription(context))."
        case .dataCorrupted(let context):
            return "Not valid JSON: \(context.debugDescription)"
        @unknown default:
            return decoding.localizedDescription
        }
    }
}
