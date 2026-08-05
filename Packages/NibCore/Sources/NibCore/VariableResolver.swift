import Foundation

/// Substitutes `{{name}}` placeholders in a template string.
///
/// A pure function over value types — no I/O, no UI, no clock, no randomness (dynamic
/// values are injected). This is what lets `NibHTTP` receive a fully-resolved `SendPlan`
/// and never see a `{{var}}` itself.
///
/// Values may themselves contain placeholders, so expansion recurses. Two things stop it
/// running away: a name already being expanded higher in the stack is a cycle, and total
/// depth is capped at `maxDepth`. Both report as `Unresolved` rather than throwing —
/// a request with one bad variable should still be sendable so the user can see the 400.
public enum VariableResolver {
    /// Chosen to comfortably exceed real-world nesting (`{{host}}` -> `{{proto}}://{{domain}}`
    /// is depth 2; anything past 10 is a mistake, not a design).
    public static let maxDepth = 10

    public struct Unresolved: Sendable, Hashable {
        public enum Reason: Sendable, Hashable {
            /// No layer defines this name.
            case undefined
            /// The name expands, directly or transitively, to itself.
            case cycle
            /// Nesting exceeded `maxDepth` without cycling. Pathological but not circular.
            case tooDeep
        }

        public let name: String
        public let reason: Reason

        public init(name: String, reason: Reason) {
            self.name = name
            self.reason = reason
        }
    }

    public struct Result: Sendable, Hashable {
        public let text: String
        /// Deduplicated and stable-ordered by first appearance, so the UI warning does not
        /// reshuffle as the user types.
        public let unresolved: [Unresolved]

        public var isFullyResolved: Bool { unresolved.isEmpty }
    }

    /// Resolve every placeholder in `template`.
    ///
    /// Unresolved placeholders are left in the output verbatim (`{{token}}` stays
    /// `{{token}}`). We deliberately do not blank them: sending a URL with a visible
    /// `{{baseUrl}}` in it produces an obvious failure, whereas silently sending
    /// `/users` against no host produces a confusing one.
    public static func resolve(
        _ template: String,
        in scope: VariableScope,
        dynamic: DynamicValues = .live
    ) -> Result {
        var unresolved: [Unresolved] = []
        var seen = Set<Unresolved>()
        var stack: [String] = []

        let context = Context(
            scope: scope,
            dynamic: dynamic,
            report: { item in
                if seen.insert(item).inserted { unresolved.append(item) }
            }
        )

        let text = expand(template, context: context, depth: 0, stack: &stack)

        return Result(text: text, unresolved: unresolved)
    }

    // MARK: - Expansion context

    /// The invariant part of a resolution pass.
    ///
    /// `scope`, `dynamic` and `report` are identical at every level of the recursion, so bundling
    /// them keeps the recursive signatures down to what actually varies: the text, the depth, and
    /// the cycle stack.
    private struct Context {
        let scope: VariableScope
        let dynamic: DynamicValues
        let report: (Unresolved) -> Void
    }

    // MARK: - Scanning

    /// The next `{{name}}` span at or after `start`, or `nil` if there is no complete one.
    ///
    /// For a run of consecutive opening braces the *innermost* pair binds, so `{{{orgId}}}`
    /// substitutes the variable and leaves the outer braces as literal text. That is both
    /// the more useful reading (a literal brace wrapping a value) and the one that matches
    /// Handlebars-style triple-stash syntax people are used to.
    ///
    /// Shared by `expand` and `placeholders` so highlighting can never disagree with what
    /// substitution actually does — a divergence there would show a variable green and
    /// then fail to resolve it.
    private static func nextPlaceholder(
        in text: String,
        from start: String.Index
    ) -> (span: Range<String.Index>, name: String)? {
        guard var open = text.range(of: "{{", range: start..<text.endIndex) else { return nil }

        while open.upperBound < text.endIndex, text[open.upperBound] == "{" {
            open = text.index(after: open.lowerBound)..<text.index(after: open.upperBound)
        }

        guard let close = text.range(of: "}}", range: open.upperBound..<text.endIndex) else {
            return nil
        }

        let name = text[open.upperBound..<close.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (open.lowerBound..<close.upperBound, name)
    }

    // MARK: - Expansion

    private static func expand(
        _ template: String,
        context: Context,
        depth: Int,
        stack: inout [String]
    ) -> String {
        // Cheap bail-out: no placeholder syntax means nothing to do. Worth having because
        // most header values and most path segments contain no variables at all.
        guard template.contains("{{") else { return template }

        var output = ""
        output.reserveCapacity(template.count)

        var index = template.startIndex
        while index < template.endIndex {
            guard let match = nextPlaceholder(in: template, from: index) else {
                // No further complete placeholder — the rest is literal.
                output += template[index...]
                break
            }

            output += template[index..<match.span.lowerBound]

            output += substitute(
                name: match.name,
                literal: String(template[match.span]),
                context: context,
                depth: depth,
                stack: &stack
            )

            index = match.span.upperBound
        }

        return output
    }

    private static func substitute(
        name: String,
        literal: String,
        context: Context,
        depth: Int,
        stack: inout [String]
    ) -> String {
        // An empty `{{}}` is not a placeholder. Emit it untouched rather than inventing
        // a meaning for it.
        guard !name.isEmpty else { return literal }

        // Dynamic values are terminal — they never contain nested placeholders, so they
        // resolve without recursing and without touching the cycle stack.
        if name.hasPrefix("$") {
            if let generated = context.dynamic.generate(name) {
                return generated
            }
            context.report(Unresolved(name: name, reason: .undefined))
            return literal
        }

        if stack.contains(name) {
            context.report(Unresolved(name: name, reason: .cycle))
            return literal
        }

        guard depth < maxDepth else {
            context.report(Unresolved(name: name, reason: .tooDeep))
            return literal
        }

        guard let value = context.scope.value(for: name) else {
            context.report(Unresolved(name: name, reason: .undefined))
            return literal
        }

        stack.append(name)
        defer { stack.removeLast() }

        return expand(value, context: context, depth: depth + 1, stack: &stack)
    }

    // MARK: - Highlighting support

    /// A placeholder's location in the source string, for the URL field's inline
    /// highlighting (green when resolved, red when not).
    public struct Placeholder: Sendable, Hashable {
        public let name: String
        public let range: Range<String.Index>
        public let isResolvable: Bool
    }

    /// Locate every placeholder without expanding anything.
    ///
    /// Runs on the main thread on every keystroke in the URL field, so it stays a single
    /// forward scan with no recursion and no allocation beyond the output array.
    public static func placeholders(
        in template: String,
        scope: VariableScope,
        dynamic: DynamicValues = .live
    ) -> [Placeholder] {
        guard template.contains("{{") else { return [] }

        var found: [Placeholder] = []
        var index = template.startIndex

        while index < template.endIndex {
            guard let match = nextPlaceholder(in: template, from: index) else { break }

            if !match.name.isEmpty {
                // `supports(_:)`, not `generate(_:)`. Probing with the generator minted a fresh
                // UUID and formatted a date on every keystroke, contradicting this function's own
                // promise of no allocation beyond the output array.
                let resolvable =
                    match.name.hasPrefix("$")
                    ? DynamicValues.supports(match.name)
                    : scope.value(for: match.name) != nil

                found.append(
                    Placeholder(name: match.name, range: match.span, isResolvable: resolvable)
                )
            }

            index = match.span.upperBound
        }

        return found
    }
}
