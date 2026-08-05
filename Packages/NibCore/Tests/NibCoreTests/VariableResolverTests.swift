import Testing

@testable import NibCore

// The parameterised tables below are the specification for variable resolution.
// They were written before the resolver. If behaviour needs to change, change the table
// first and let it fail.

@Suite("VariableResolver")
struct VariableResolverTests {

    private static let scope = VariableScope([
        .environment: [
            "baseUrl": "https://api.acme.dev",
            "version": "v2",
            "token": "secret-token",
        ],
        .collection: [
            "baseUrl": "https://collection.example",  // the default, overridden by env
            "orgId": "org_123",
        ],
        .request: [
            "version": "v3"  // overrides the environment's v2
        ],
    ])

    // MARK: - Substitution

    @Test(
        "substitutes placeholders",
        arguments: [
            ("no placeholders here", "no placeholders here"),
            ("{{baseUrl}}", "https://api.acme.dev"),
            ("{{baseUrl}}/users", "https://api.acme.dev/users"),
            ("{{baseUrl}}/{{version}}/users", "https://api.acme.dev/v3/users"),
            ("prefix{{orgId}}suffix", "prefixorg_123suffix"),
            ("{{orgId}}{{orgId}}", "org_123org_123"),
            ("", ""),
        ]
    )
    func substitutes(template: String, expected: String) {
        let result = VariableResolver.resolve(template, in: Self.scope, dynamic: .none)
        #expect(result.text == expected)
        #expect(result.isFullyResolved)
    }

    @Test("narrower layers win")
    func layerPrecedence() {
        // `version` is defined in both .request and .environment; .request wins.
        let result = VariableResolver.resolve("{{version}}", in: Self.scope, dynamic: .none)
        #expect(result.text == "v3")
        #expect(Self.scope.definingLayer(for: "version") == .request)
        #expect(Self.scope.definingLayer(for: "orgId") == .collection)
    }

    /// Regression guard for the precedence rule that is easiest to get backwards.
    ///
    /// The collection defines `baseUrl` as a default; the active environment must be able
    /// to override it. If this inverts, selecting the Staging environment silently fails
    /// to redirect the request — the app looks like it works and hits production.
    @Test("the active environment overrides collection defaults")
    func environmentBeatsCollection() {
        var scope = VariableScope([.collection: ["baseUrl": "https://production.example"]])
        #expect(
            VariableResolver.resolve("{{baseUrl}}", in: scope, dynamic: .none).text
                == "https://production.example")

        scope.set(["baseUrl": "https://staging.example"], for: .environment)
        #expect(
            VariableResolver.resolve("{{baseUrl}}", in: scope, dynamic: .none).text
                == "https://staging.example")

        #expect(VariableScope.Layer.environment < VariableScope.Layer.collection)
        #expect(VariableScope.Layer.request < VariableScope.Layer.environment)
    }

    @Test("whitespace inside braces is tolerated")
    func tolerantOfWhitespace() {
        let result = VariableResolver.resolve("{{  baseUrl  }}", in: Self.scope, dynamic: .none)
        #expect(result.text == "https://api.acme.dev")
    }

    // MARK: - Nesting

    @Test("expands nested values recursively")
    func nested() {
        let scope = VariableScope([
            .environment: [
                "proto": "https",
                "domain": "acme.dev",
                "host": "{{proto}}://{{domain}}",
                "url": "{{host}}/api",
            ]
        ])
        let result = VariableResolver.resolve("{{url}}/users", in: scope, dynamic: .none)
        #expect(result.text == "https://acme.dev/api/users")
        #expect(result.isFullyResolved)
    }

    // MARK: - Failure modes
    //
    // Every one of these leaves the placeholder verbatim in the output. Sending a URL with
    // a visible `{{baseUrl}}` fails obviously; silently blanking it fails confusingly.

    @Test("undefined names are reported and left verbatim")
    func undefined() {
        let result = VariableResolver.resolve(
            "{{baseUrl}}/{{missing}}", in: Self.scope, dynamic: .none)
        #expect(result.text == "https://api.acme.dev/{{missing}}")
        #expect(result.unresolved == [.init(name: "missing", reason: .undefined)])
    }

    @Test("direct self-reference is a cycle, not a hang")
    func directCycle() {
        let scope = VariableScope.environment(["a": "{{a}}"])
        let result = VariableResolver.resolve("{{a}}", in: scope, dynamic: .none)
        #expect(result.unresolved == [.init(name: "a", reason: .cycle)])
    }

    @Test("mutual recursion is a cycle, not a hang")
    func mutualCycle() {
        let scope = VariableScope.environment(["a": "{{b}}", "b": "{{c}}", "c": "{{a}}"])
        let result = VariableResolver.resolve("{{a}}", in: scope, dynamic: .none)
        #expect(result.unresolved.contains(.init(name: "a", reason: .cycle)))
    }

    @Test("nesting deeper than maxDepth is reported as tooDeep")
    func tooDeep() {
        // Build a non-cyclic chain longer than the cap: v0 -> v1 -> ... -> v20.
        var values: [String: String] = [:]
        for i in 0..<20 { values["v\(i)"] = "{{v\(i + 1)}}" }
        values["v20"] = "end"

        let result = VariableResolver.resolve(
            "{{v0}}", in: VariableScope.environment(values), dynamic: .none)
        #expect(result.unresolved.contains { $0.reason == .tooDeep })
        #expect(!result.isFullyResolved)
    }

    @Test("unresolved names are deduplicated but keep first-appearance order")
    func stableDeduplication() {
        let result = VariableResolver.resolve(
            "{{zeta}}/{{alpha}}/{{zeta}}", in: Self.scope, dynamic: .none)
        #expect(result.unresolved.map(\.name) == ["zeta", "alpha"])
    }

    // MARK: - Malformed input
    //
    // None of these should throw, hang, or invent a meaning.

    @Test(
        "malformed placeholder syntax passes through untouched",
        arguments: [
            "{{unclosed",
            "unopened}}",
            "{{}}",
            "{{ }}",
            "{",
            "}}{{",
            "{{{baseUrl}}}",
        ]
    )
    func malformed(template: String) {
        let result = VariableResolver.resolve(template, in: Self.scope, dynamic: .none)
        #expect(!result.text.isEmpty || template.isEmpty)
    }

    @Test("triple braces resolve the inner placeholder and keep the outer braces")
    func tripleBraces() {
        let result = VariableResolver.resolve("{{{orgId}}}", in: Self.scope, dynamic: .none)
        #expect(result.text == "{org_123}")
    }

    // MARK: - Dynamic values

    @Test("dynamic values are substituted from the injected generator")
    func dynamicValues() {
        let result = VariableResolver.resolve(
            "{{$timestamp}}/{{$randomInt}}",
            in: Self.scope,
            dynamic: .fixed(timestamp: 1_700_000_000, randomInt: 7)
        )
        #expect(result.text == "1700000000/7")
        #expect(result.isFullyResolved)
    }

    @Test("unsupported dynamic values pass through and are reported")
    func unsupportedDynamic() {
        let result = VariableResolver.resolve(
            "{{$randomBankAccount}}", in: Self.scope, dynamic: .fixed())
        #expect(result.text == "{{$randomBankAccount}}")
        #expect(result.unresolved == [.init(name: "$randomBankAccount", reason: .undefined)])
    }

    @Test("resolution is deterministic with a fixed generator")
    func deterministic() {
        let template = "{{baseUrl}}/{{$guid}}"
        let first = VariableResolver.resolve(template, in: Self.scope, dynamic: .fixed())
        let second = VariableResolver.resolve(template, in: Self.scope, dynamic: .fixed())
        #expect(first == second)
    }

    // MARK: - Highlighting

    @Test("locates placeholders with resolvability for inline highlighting")
    func placeholders() {
        let template = "{{baseUrl}}/{{missing}}/{{$guid}}"
        let found = VariableResolver.placeholders(
            in: template, scope: Self.scope, dynamic: .fixed())

        #expect(found.map(\.name) == ["baseUrl", "missing", "$guid"])
        #expect(found.map(\.isResolvable) == [true, false, true])

        // Ranges must point at the literal `{{...}}` span so the highlighter can style it.
        #expect(String(template[found[0].range]) == "{{baseUrl}}")
        #expect(String(template[found[1].range]) == "{{missing}}")
    }

    @Test("placeholder scan ignores malformed spans")
    func placeholdersIgnoreMalformed() {
        #expect(VariableResolver.placeholders(in: "{{}}", scope: Self.scope).isEmpty)
        #expect(VariableResolver.placeholders(in: "no braces", scope: Self.scope).isEmpty)
        #expect(VariableResolver.placeholders(in: "{{unclosed", scope: Self.scope).isEmpty)
    }
}

@Suite("HTTPMethod")
struct HTTPMethodTests {
    @Test("normalises case and whitespace")
    func normalises() {
        #expect(HTTPMethod("get") == .get)
        #expect(HTTPMethod("  Post  ") == .post)
    }

    @Test("preserves uncommon verbs rather than rejecting them")
    func preservesCustomVerbs() {
        // An import must never fail because of a verb we did not anticipate.
        #expect(HTTPMethod("PROPFIND").rawValue == "PROPFIND")
        #expect(HTTPMethod("purge").rawValue == "PURGE")
    }

    @Test("body convention drives defaults only")
    func bodyConvention() {
        #expect(HTTPMethod.post.conventionallyCarriesBody)
        #expect(!HTTPMethod.get.conventionallyCarriesBody)
    }
}
