import NibCore
import SwiftUI

// The per-tab editors of the request pane. Each is a real `View` type rather than a computed
// property on `RequestPane`, because a computed property does not get `@Observable`'s fine-grained
// invalidation — editing a header would redraw the body editor too.

// MARK: - Parameters

/// Query and path parameters in one table, which is how Postman stores them and how people think
/// about them. The picker moves a row between the two without losing its value.
struct ParamEditor: View {
    @Binding var params: [Param]

    var body: some View {
        KeyValueTable(
            rows: $params,
            keyPath: \.name,
            valuePath: \.value,
            enabledPath: \.enabled,
            makeRow: { Param(kind: .query, name: $0, value: "") },
            keyPlaceholder: "Name",
            accessory: { param in
                Picker("", selection: param.kind) {
                    Text("Query").tag(Param.Kind.query)
                    Text("Path").tag(Param.Kind.path)
                }
                .labelsHidden()
                .frame(width: 88)
                .help("Query parameters go after the ?; path parameters replace :name in the path")
            }
        )
    }
}

// MARK: - Auth

/// The five schemes v1 supports.
///
/// Everything else Postman offers — OAuth 2.0 flows, AWS SigV4, digest, NTLM, hawk — is imported
/// into `preserved`, reported, and round-tripped untouched. The footer says so, because someone
/// looking at this picker for a scheme that is not here needs to know their config still exists.
struct AuthEditor: View {
    @Binding var auth: AuthSpec
    let inherited: AuthSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Auth", selection: kind) {
                ForEach(AuthKind.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 320)

            switch auth {
            case .none:
                Caption("No authorization header is added.")
            case .inherit:
                InheritedAuthSummary(inherited: inherited)
            case .bearer:
                LabelledField("Token", text: bearerToken, isSecret: true)
            case .basic:
                LabelledField("Username", text: basicUsername)
                LabelledField("Password", text: basicPassword, isSecret: true)
            case .apiKey:
                LabelledField("Key", text: apiKeyName)
                LabelledField("Value", text: apiKeyValue, isSecret: true)
                Picker("Add to", selection: apiKeyPlacement) {
                    Text("Header").tag(AuthSpec.APIKeyPlacement.header)
                    Text("Query string").tag(AuthSpec.APIKeyPlacement.query)
                }
                .frame(width: 320)
                if case .apiKey(_, _, .query) = auth {
                    Caption(
                        "Query strings are logged by proxies and servers far more often than "
                            + "headers are.", isWarning: true)
                }
            }

            Caption(
                "Values here accept {{variables}}, so a token can live in an environment "
                    + "and stay out of your files.")

            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Bindings
    //
    // Each field reads out of the current case and writes a whole new case back. Slightly verbose,
    // and the alternative — mirroring the fields into `@State` — is the bug that already bit the
    // body editor: the mirror goes stale the moment something external replaces the request.

    private var kind: Binding<AuthKind> {
        Binding(
            get: { AuthKind(auth) },
            set: { auth = $0.makeSpec(preserving: auth) }
        )
    }

    private var bearerToken: Binding<String> {
        Binding(
            get: {
                guard case .bearer(let token) = auth else { return "" }
                return token
            },
            set: { auth = .bearer(token: $0) })
    }

    private var basicUsername: Binding<String> {
        Binding(
            get: {
                guard case .basic(let user, _) = auth else { return "" }
                return user
            },
            set: { auth = .basic(username: $0, password: basicPassword.wrappedValue) })
    }

    private var basicPassword: Binding<String> {
        Binding(
            get: {
                guard case .basic(_, let password) = auth else { return "" }
                return password
            },
            set: { auth = .basic(username: basicUsername.wrappedValue, password: $0) })
    }

    private var apiKeyName: Binding<String> {
        Binding(
            get: {
                guard case .apiKey(let name, _, _) = auth else { return "" }
                return name
            },
            set: {
                auth = .apiKey(
                    name: $0, value: apiKeyValue.wrappedValue,
                    placement: apiKeyPlacement.wrappedValue)
            })
    }

    private var apiKeyValue: Binding<String> {
        Binding(
            get: {
                guard case .apiKey(_, let value, _) = auth else { return "" }
                return value
            },
            set: {
                auth = .apiKey(
                    name: apiKeyName.wrappedValue, value: $0,
                    placement: apiKeyPlacement.wrappedValue)
            })
    }

    private var apiKeyPlacement: Binding<AuthSpec.APIKeyPlacement> {
        Binding(
            get: {
                if case .apiKey(_, _, let placement) = auth { return placement }
                return .header
            },
            set: {
                auth = .apiKey(
                    name: apiKeyName.wrappedValue, value: apiKeyValue.wrappedValue, placement: $0)
            })
    }
}

/// The picker's cases, separate from `AuthSpec` so switching schemes can keep what was typed.
enum AuthKind: String, CaseIterable, Identifiable {
    case inherit, none, bearer, basic, apiKey

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inherit: "Inherit from parent"
        case .none: "No auth"
        case .bearer: "Bearer token"
        case .basic: "Basic"
        case .apiKey: "API key"
        }
    }

    init(_ spec: AuthSpec) {
        switch spec {
        case .inherit: self = .inherit
        case .none: self = .none
        case .bearer: self = .bearer
        case .basic: self = .basic
        case .apiKey: self = .apiKey
        }
    }

    /// Switching schemes and switching back must not silently empty the fields.
    func makeSpec(preserving current: AuthSpec) -> AuthSpec {
        switch self {
        case .inherit: return .inherit
        case .none: return .none
        case .bearer:
            if case .bearer = current { return current }
            return .bearer(token: "")
        case .basic:
            if case .basic = current { return current }
            return .basic(username: "", password: "")
        case .apiKey:
            if case .apiKey = current { return current }
            return .apiKey(name: "", value: "", placement: .header)
        }
    }
}

/// What `.inherit` actually resolves to, spelled out.
///
/// "Inherit" is the default, so most requests show this — and a request that quietly sends no
/// credentials because nothing up the chain defines any is a confusing 401 waiting to happen.
private struct InheritedAuthSummary: View {
    let inherited: AuthSpec

    var body: some View {
        switch inherited {
        case .none, .inherit:
            Caption(
                "Nothing up the folder chain defines auth, so this request sends none.",
                isWarning: true)
        case .bearer:
            Caption("Inheriting a bearer token from the folder or collection.")
        case .basic(let username, _):
            Caption("Inheriting basic auth for \(username.isEmpty ? "(no username)" : username).")
        case .apiKey(let name, _, let placement):
            Caption("Inheriting API key \(name) in the \(placement.rawValue).")
        }
    }
}

// MARK: - Settings

struct SettingsEditor: View {
    @Binding var settings: RequestSettings

    var body: some View {
        Form {
            Section {
                LabeledContent("Timeout") {
                    HStack(spacing: 6) {
                        TextField(
                            "", value: $settings.timeoutMilliseconds, format: .number
                        )
                        .frame(width: 90)
                        Text("ms").foregroundStyle(.secondary)
                    }
                }
            }

            Section("Redirects") {
                Toggle("Follow redirects", isOn: $settings.followRedirects)
                LabeledContent("Maximum") {
                    TextField("", value: $settings.maximumRedirects, format: .number)
                        .frame(width: 60)
                        .disabled(!settings.followRedirects)
                }
                Toggle(
                    "Keep the method across 301, 302 and 303",
                    isOn: $settings.preserveMethodOnRedirect
                )
                .disabled(!settings.followRedirects)
                Caption(
                    "Foundation rewrites POST to GET on those codes, matching browsers. Turn this "
                        + "on for an API that expects the method to survive.")
            }

            Section("Body") {
                Toggle("Send a body on GET and DELETE", isOn: $settings.sendBodyOnGet)
                Caption("Unusual, but some search APIs require it.")
            }

            Section("TLS") {
                Toggle("Verify the certificate", isOn: $settings.verifyTLS)
                if !settings.verifyTLS {
                    Caption(
                        "Off. Anyone on the network can read and change this request.",
                        isWarning: true)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Small shared pieces

struct Caption: View {
    let text: String
    var isWarning = false

    init(_ text: String, isWarning: Bool = false) {
        self.text = text
        self.isWarning = isWarning
    }

    var body: some View {
        Label(text, systemImage: isWarning ? "exclamationmark.triangle" : "info.circle")
            .symbolRenderingMode(.hierarchical)
            .font(.callout)
            .foregroundStyle(isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A labelled text field that can hide its contents.
///
/// `SecureField` for credentials, with a reveal toggle — an API client is a debugging tool, and
/// "is my token actually what I think it is" is a question people need to answer by looking.
struct LabelledField: View {
    let title: String
    @Binding var text: String
    var isSecret = false

    @State private var isRevealed = false

    init(_ title: String, text: Binding<String>, isSecret: Bool = false) {
        self.title = title
        self._text = text
        self.isSecret = isSecret
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(width: 90, alignment: .trailing)
                .foregroundStyle(.secondary)

            if isSecret && !isRevealed {
                SecureField(title, text: $text)
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField(title, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            if isSecret {
                Button(
                    isRevealed ? "Hide" : "Reveal",
                    systemImage: isRevealed ? "eye.slash" : "eye"
                ) {
                    isRevealed.toggle()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(isRevealed ? "Hide" : "Reveal")
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }
}
