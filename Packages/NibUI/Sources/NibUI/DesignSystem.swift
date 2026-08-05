import NibCore
import SwiftUI

// The small set of shared visual decisions, in one file.
//
// Not a "design system" in the framework sense — there is no theming layer, no protocol, no
// injectable style provider. `AGENTS.md` calls that defensive complexity in a 5 MB app and it is
// right. What lives here is the narrower thing: the values and two view types that were previously
// written out five times each, slightly differently, in five files.
//
// The specific duplication this replaces:
//
//   - status-code → colour, written three times (response pill, history row, redirect hop) with
//     three different range sets, so a 204 was green in one place and grey in another.
//   - the small filled monospaced pill, written five times with corner radii of 4, 4, 5, 5 and
//     a Capsule.
//   - the inline notice strip, written three times as `.background(.quaternary.opacity(0.4))`,
//     which is exactly the kind of hand-rolled background macOS 26 asks apps to stop drawing.

// MARK: - Metrics

/// The spacing scale.
///
/// Three values, because the pane padding was 12/8 in one file, 10/6 in another and 12/6 in a third
/// and the difference was not carrying any meaning.
enum Metrics {
    /// Inside a badge or a chip.
    static let chip: CGFloat = 6
    /// Between rows, and the vertical padding of a bar.
    static let row: CGFloat = 8
    /// The horizontal inset of anything that sits directly in a pane.
    static let pane: CGFloat = 12
}

// MARK: - Semantic colour

/// Status-code colour, defined once.
///
/// `2xx` is not simply "green": a `204 No Content` answering a `GET` is usually not what you wanted,
/// but it is still a success, so the distinction stays out of the colour and in the text. What the
/// colour has to carry is the coarse question — did this work, was I redirected, whose fault is it.
enum StatusStyle {
    static func colour(for status: Int) -> Color {
        switch status {
        case 100..<200: .secondary
        case 200..<300: .green
        case 300..<400: .orange
        case 400..<500: .red
        case 500...: .purple
        default: .secondary
        }
    }

    /// 4xx and 5xx are different failures — one is the request, one is the server — and telling them
    /// apart at a glance is most of what this pane is for. Purple rather than a darker red because a
    /// red/darker-red pair is not distinguishable for the most common colour vision deficiencies.
    static func label(for status: Int) -> String {
        switch status {
        case 100..<200: "Informational"
        case 200..<300: "Success"
        case 300..<400: "Redirect"
        case 400..<500: "Client error"
        case 500...: "Server error"
        default: "Unknown"
        }
    }
}

/// Method colour, defined once.
///
/// Follows the convention every API client uses, so the sidebar is scannable without reading the
/// text. Deliberately the *same* palette as `StatusStyle` where the meaning lines up — destructive
/// is red in both.
enum MethodStyle {
    static func colour(for method: HTTPMethod) -> Color {
        switch method {
        case .get: .blue
        case .post: .green
        case .put, .patch: .orange
        case .delete: .red
        default: .secondary
        }
    }
}

// MARK: - Badge

/// The small filled or quiet pill: a status code, a protocol, a cookie attribute.
///
/// A `Capsule` rather than a rounded rectangle, and that is a macOS 26 decision rather than a taste
/// one. The system moved its own small controls to capsule and rounded-rectangle shapes chosen by
/// control size; a hand-picked 4pt radius now reads as a control from the previous OS sitting next
/// to ones that are not.
struct Badge: View {
    enum Prominence {
        /// Filled with `tint`, white text. For the one value in a row that matters.
        case filled
        /// Quaternary fill, secondary text. For metadata that should be legible but quiet.
        case quiet
    }

    let text: String
    var prominence: Prominence = .quiet
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold).monospaced())
            // Digits in a status code should not shift width when 200 becomes 404 in place.
            .monospacedDigit()
            .foregroundStyle(
                prominence == .filled ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary)
            )
            .padding(.horizontal, Metrics.chip)
            .padding(.vertical, 2)
            .background(
                prominence == .filled ? AnyShapeStyle(tint) : AnyShapeStyle(.quaternary),
                in: .capsule
            )
    }
}

// MARK: - Banner

/// The inline notice strip: unresolved variables, load diagnostics, "you are only seeing part of
/// this".
///
/// Uses `.bar` rather than a hand-mixed `.quaternary.opacity(0.4)`. Two reasons, and the second is
/// the load-bearing one: `.bar` is the material the system also uses for the toolbar and the
/// sidebar, so a banner sits in the same visual layer as the window chrome instead of hovering in
/// an invented one; and it adapts on its own to Reduce Transparency and Increase Contrast, which a
/// fixed-opacity grey does not.
struct Banner<Content: View>: View {
    enum Severity {
        case info
        case warning

        var symbol: String {
            switch self {
            case .info: "info.circle"
            case .warning: "exclamationmark.triangle"
            }
        }

        var tint: Color {
            switch self {
            case .info: .secondary
            case .warning: .orange
            }
        }
    }

    let severity: Severity
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.row) {
            Image(systemName: severity.symbol)
                // Hierarchical rather than monochrome so the glyph reads as one shape with internal
                // depth at 11pt instead of a solid blob.
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(severity.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .padding(.horizontal, Metrics.pane)
        .padding(.vertical, Metrics.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

// MARK: - Bar

/// The chrome strip at the top or bottom of a pane — the filter field, the sidebar footer, the
/// response status row.
///
/// Exists to hold one decision in one place: these strips draw **no background of their own**.
/// Adopting Liquid Glass is mostly a subtraction — the system supplies the material for anything it
/// recognises as chrome, and a custom background painted underneath is what stops it. Where the
/// strip is attached with `safeAreaBar`, SwiftUI also gives the scroll view behind it a scroll edge
/// effect, so content fades out under the bar instead of colliding with it.
struct PaneBar<Content: View>: View {
    var horizontal: CGFloat = Metrics.pane
    var vertical: CGFloat = Metrics.chip
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: Metrics.row) { content }
            .padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
