import Foundation
import NibCore

/// Turns a `curl` command line into an `HTTPRequestSpec`.
///
/// The highest-value small feature in the project: a day and a half of work, and it is the one
/// people screenshot. Copy as cURL in devtools, paste into Nib, press send.
///
/// Three categories of flag, and the distinction is the whole design:
///   - **Supported** — changes the request we build.
///   - **Ignored** — about curl's own output (`-s`, `-v`, `-o`), meaningless here. Silently dropped
///     is correct; they say nothing about the request.
///   - **Reported** — recognised but not representable in v1. Never silently dropped.
public enum CurlImporter: Importer {

    public static func canHandle(_ data: Data, filename: String) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return looksLikeCurl(text)
    }

    public static func looksLikeCurl(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("curl ") || trimmed.hasPrefix("curl.exe")
            || trimmed == "curl" || trimmed.hasPrefix("curl\n") || trimmed.hasPrefix("curl\t")
    }

    public static func importing(_ data: Data) throws -> ImportResult {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ImportError.malformed(reason: "Not valid UTF-8.")
        }
        let parsed = try parse(text)
        return ImportResult(
            collectionName: parsed.spec.url,
            requestCount: 1,
            diagnostics: parsed.diagnostics
        )
    }

    public struct Parsed: Sendable {
        public var spec: HTTPRequestSpec
        public var diagnostics: [ImportDiagnostic]
    }

    /// Parse a command into a request.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public static func parse(_ command: String) throws -> Parsed {
        var tokens = try ShellLexer.tokenize(command)

        // Drop the leading `curl` / `curl.exe`, and tolerate its absence — people paste bare URLs
        // and bare flag lists too.
        if let first = tokens.first,
            first == "curl" || first == "curl.exe" || first.hasSuffix("/curl")
        {
            tokens.removeFirst()
        }

        var spec = HTTPRequestSpec(method: .get, url: "")
        var diagnostics: [ImportDiagnostic] = []
        var explicitMethod: HTTPMethod?
        var dataParts: [String] = []
        var urlEncodeParts: [Param] = []
        var formParts: [MultipartPart] = []
        var isFormData = false
        var forceGetWithData = false
        var jsonShorthand = false
        var uploadFile: String?
        var positionalURL: String?

        func note(_ severity: ImportDiagnostic.Severity, _ message: String) {
            diagnostics.append(
                ImportDiagnostic(severity: severity, path: "curl", message: message))
        }

        var index = 0
        while index < tokens.count {
            let token = tokens[index]

            /// The value for a flag: either the next token, or the remainder of `--flag=value`.
            func value(_ inlineValue: String?) throws -> String {
                if let inlineValue { return inlineValue }
                guard index + 1 < tokens.count else {
                    throw ImportError.malformed(reason: "\(token) needs a value.")
                }
                index += 1
                return tokens[index]
            }

            // Split `--flag=value` once, so every case below can just call value(inline).
            var flag = token
            var inline: String?
            if token.hasPrefix("--"), let equals = token.firstIndex(of: "=") {
                flag = String(token[token.startIndex..<equals])
                inline = String(token[token.index(after: equals)...])
            }

            switch flag {
            case "-X", "--request":
                explicitMethod = HTTPMethod(try value(inline))

            case "--url":
                spec.url = try value(inline)

            case "-H", "--header":
                let raw = try value(inline)
                if let colon = raw.firstIndex(of: ":") {
                    let name = String(raw[raw.startIndex..<colon])
                        .trimmingCharacters(in: .whitespaces)
                    let headerValue = String(raw[raw.index(after: colon)...])
                        .trimmingCharacters(in: .whitespaces)
                    // `-H 'Name;'` is curl's syntax for removing a header it would otherwise send.
                    if headerValue.isEmpty, name.hasSuffix(";") {
                        note(.dropped, "Header suppression (\(raw)) is not supported.")
                    } else {
                        spec.headers.append(HeaderField(name: name, value: headerValue))
                    }
                } else {
                    note(.dropped, "Could not parse header \"\(raw)\" — no colon.")
                }

            case "-d", "--data", "--data-raw", "--data-ascii", "--data-binary":
                dataParts.append(try value(inline))

            case "--data-urlencode":
                let raw = try value(inline)
                if let equals = raw.firstIndex(of: "=") {
                    urlEncodeParts.append(
                        Param(
                            name: String(raw[raw.startIndex..<equals]),
                            value: String(raw[raw.index(after: equals)...])))
                } else {
                    urlEncodeParts.append(Param(name: raw, value: ""))
                }

            case "--json":
                // Shorthand for --data + Content-Type + Accept, all application/json.
                jsonShorthand = true
                dataParts.append(try value(inline))

            case "-F", "--form", "--form-string":
                isFormData = true
                let raw = try value(inline)
                if let equals = raw.firstIndex(of: "=") {
                    let name = String(raw[raw.startIndex..<equals])
                    let rest = String(raw[raw.index(after: equals)...])
                    if rest.hasPrefix("@") || rest.hasPrefix("<") {
                        formParts.append(
                            .init(name: name, content: .file(path: String(rest.dropFirst()))))
                    } else {
                        formParts.append(.init(name: name, content: .text(rest)))
                    }
                } else {
                    note(.dropped, "Could not parse form field \"\(raw)\".")
                }

            case "-u", "--user":
                let raw = try value(inline)
                let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
                // Auth, not a raw header, so it round-trips and shows in the Auth tab.
                spec.auth = .basic(
                    username: parts.first ?? "",
                    password: parts.count > 1 ? parts[1] : "")

            case "-A", "--user-agent":
                spec.headers.append(HeaderField(name: "User-Agent", value: try value(inline)))

            case "-e", "--referer":
                spec.headers.append(HeaderField(name: "Referer", value: try value(inline)))

            case "-b", "--cookie":
                spec.headers.append(HeaderField(name: "Cookie", value: try value(inline)))

            case "-G", "--get":
                forceGetWithData = true

            case "-I", "--head":
                explicitMethod = .head

            case "-L", "--location":
                spec.settings.followRedirects = true

            case "--max-redirs":
                spec.settings.maximumRedirects = Int(try value(inline)) ?? 10

            case "-k", "--insecure":
                spec.settings.verifyTLS = false

            case "-T", "--upload-file":
                uploadFile = try value(inline)

            case "-m", "--max-time":
                if let seconds = Double(try value(inline)) {
                    spec.settings.timeoutMilliseconds = Int(seconds * 1000)
                }

            case "--compressed", "--no-progress-meter", "--fail", "-f":
                break  // About curl's behaviour, not the request.

            // Output and progress control: nothing to represent.
            case "-s", "--silent", "-S", "--show-error", "-v", "--verbose", "-i", "--include",
                "-#", "--progress-bar", "-o", "--output", "-O", "--remote-name", "--no-buffer",
                "-w", "--write-out", "--retry", "--retry-delay", "--retry-max-time", "-N":
                // The ones that take a value must consume it, or it gets mistaken for the URL.
                let takesValue: Set<String> = [
                    "-o", "--output", "-w", "--write-out",
                    "--retry", "--retry-delay", "--retry-max-time",
                ]
                if takesValue.contains(flag), inline == nil, index + 1 < tokens.count {
                    index += 1
                }

            case "-x", "--proxy", "--socks5", "--socks5-hostname":
                _ = try value(inline)
                note(.dropped, "Proxy configuration is not supported in v1.")

            case "-E", "--cert", "--key", "--cacert", "--capath":
                _ = try value(inline)
                note(.dropped, "Client certificates are not supported in v1.")

            case "--digest", "--ntlm", "--negotiate", "--anyauth":
                note(
                    .dropped,
                    "\(flag) authentication is not supported in v1. Basic and Bearer are.")

            default:
                if flag.hasPrefix("-") {
                    note(.preserved, "Unrecognised flag \(flag) was ignored.")
                    // Unknown long flags conventionally take a value; guess conservatively and
                    // only consume a following token if it does not look like another flag.
                    if flag.hasPrefix("--"), inline == nil, index + 1 < tokens.count,
                        !tokens[index + 1].hasPrefix("-")
                    {
                        index += 1
                    }
                } else if positionalURL == nil {
                    positionalURL = token
                } else {
                    note(.dropped, "Ignored extra argument \"\(token)\" — Nib imports one request.")
                }
            }

            index += 1
        }

        if spec.url.isEmpty {
            spec.url = positionalURL ?? ""
        }
        guard !spec.url.isEmpty else {
            throw ImportError.malformed(reason: "No URL found in the command.")
        }

        // MARK: Body and method inference
        //
        // These rules are curl's, and getting them wrong produces a request that looks right and
        // behaves differently.

        let joinedData = dataParts.joined(separator: "&")

        if forceGetWithData, !joinedData.isEmpty {
            // -G moves the data into the query string instead of the body.
            spec.url += (spec.url.contains("?") ? "&" : "?") + joinedData
            dataParts = []
        }

        if isFormData {
            spec.body = .multipart(formParts)
            note(
                .preserved,
                "Multipart form data was imported but cannot be sent until Phase 7.")
        } else if let uploadFile {
            spec.body = .binary(path: uploadFile)
        } else if !urlEncodeParts.isEmpty {
            spec.body = .urlEncoded(urlEncodeParts)
        } else if !joinedData.isEmpty, !forceGetWithData {
            if joinedData.hasPrefix("@") {
                spec.body = .binary(path: String(joinedData.dropFirst()))
            } else {
                spec.body = .raw(text: joinedData, language: inferLanguage(joinedData))
            }
        }

        // Method: an explicit -X always wins.
        //
        // The upload check must come BEFORE the generic body rule: `-T file` already set the body,
        // so testing `spec.body != .none` first would classify every upload as POST and never reach
        // the PUT branch. curl uploads with PUT.
        if let explicitMethod {
            spec.method = explicitMethod
        } else if uploadFile != nil {
            spec.method = .put
        } else if spec.body != .none, !forceGetWithData {
            spec.method = .post
        }

        if jsonShorthand {
            addHeaderIfAbsent(&spec, name: "Content-Type", value: "application/json")
            addHeaderIfAbsent(&spec, name: "Accept", value: "application/json")
        }

        // Body-on-GET has to be explicit, and curl really does send it, so preserve the intent.
        if spec.body != .none, !spec.method.conventionallyCarriesBody {
            spec.settings.sendBodyOnGet = true
        }

        if !spec.settings.verifyTLS {
            note(.adjusted, "TLS verification is off for this request (-k was present).")
        }

        return Parsed(spec: spec, diagnostics: diagnostics)
    }

    // MARK: - Helpers

    private static func addHeaderIfAbsent(
        _ spec: inout HTTPRequestSpec,
        name: String,
        value: String
    ) {
        let exists = spec.headers.contains {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
        guard !exists else { return }
        spec.headers.append(HeaderField(name: name, value: value))
    }

    /// Guess the raw-body language so the editor highlights it and the right Content-Type is set.
    private static func inferLanguage(_ body: String) -> BodySpec.RawLanguage {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            // Only claim JSON if it actually parses; a form body can start with a brace.
            if (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil {
                return .json
            }
        }
        if trimmed.hasPrefix("<") { return .xml }
        return .text
    }
}
