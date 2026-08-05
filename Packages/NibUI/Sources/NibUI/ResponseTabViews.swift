import NibCore
import NibStore
import SwiftUI

// The response pane's secondary tabs: history, headers, and cookies. Each is a real `View` type,
// not a computed property on the pane -- computed properties do not get `@Observable`'s
// fine-grained invalidation, so switching tabs would redraw all of them.

/// Past responses for the selected request.
///
/// Metadata and a body preview, not a full replay: history lives in Application Support and storing
/// twenty complete payloads per request would put hundreds of megabytes there for one busy endpoint.
/// Recognising a response is what this is for.
struct HistoryList: View {
    var model: AppModel

    var body: some View {
        if model.history.isEmpty {
            ContentUnavailableView(
                "No history yet",
                systemImage: "clock.arrow.circlepath",
                description: Text("Responses to this request will be listed here, newest first.")
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.history) { entry in
                        HistoryRow(entry: entry)
                        Divider()
                    }
                }
            }
        }
    }
}

struct HistoryRow: View {
    let entry: HistoryStore.Entry

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Badge(
                    text: "\(entry.status)",
                    prominence: .filled,
                    tint: StatusStyle.colour(for: entry.status)
                )
                .accessibilityLabel(
                    "\(StatusStyle.label(for: entry.status)): \(entry.status)")

                Text(entry.date.formatted(date: .omitted, time: .standard))
                Text(String(format: "%.0f ms", entry.durationMilliseconds))
                    .foregroundStyle(.secondary)
                Text(entry.byteCount.formatted(.byteCount(style: .binary)))
                    .foregroundStyle(.secondary)

                Spacer()

                Button(isExpanded ? "Hide body" : "Show body") { isExpanded.toggle() }
                    .buttonStyle(.borderless)
                    .font(.callout)
            }
            .font(.system(.callout, design: .monospaced))
            .monospacedDigit()

            Text(entry.url)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            if isExpanded {
                ScrollView {
                    Text(entry.bodyPreview)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .padding(Metrics.row)
                // `ConcentricRectangle` rather than a picked radius: this box is nested inside the
                // pane, which is nested inside the window, and macOS 26 made those outer radii
                // larger. Concentric corners are derived from the container's curvature, so the
                // inset box stays visually parallel to the window's corner instead of drifting.
                .background(.quaternary.opacity(0.3), in: ConcentricRectangle())
                .transition(.opacity.combined(with: .move(edge: .top)))

                if entry.isBodyTruncated {
                    Text("Preview only — history keeps the first 64 KB.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, Metrics.pane)
        .padding(.vertical, Metrics.chip)
        .animation(.smooth(duration: 0.2), value: isExpanded)
    }
}

struct HeaderList: View {
    let headers: [SendPlan.Header]

    var body: some View {
        if headers.isEmpty {
            ContentUnavailableView(
                "No headers",
                systemImage: "list.bullet.rectangle",
                description: Text("The response came back with none.")
            )
        } else {
            list
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                    HStack(alignment: .top, spacing: 8) {
                        Text(header.name)
                            .fontWeight(.medium)
                            .frame(width: 220, alignment: .leading)
                        Text(header.value)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .font(.system(.callout, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    Divider()
                }
            }
        }
    }
}

struct CookieList: View {
    let cookies: [ResponseViewModel.Cookie]

    var body: some View {
        if cookies.isEmpty {
            ContentUnavailableView(
                "No cookies",
                systemImage: "birthday.cake",
                description: Text("Nothing in this response set one.")
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(cookies, id: \.self) { cookie in
                        CookieRow(cookie: cookie)
                        Divider()
                    }
                }
            }
        }
    }
}

struct CookieRow: View {
    let cookie: ResponseViewModel.Cookie

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(cookie.name).fontWeight(.medium)
                Text(cookie.value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            HStack(spacing: Metrics.chip) {
                ForEach(attributes, id: \.self) { attribute in
                    Badge(text: attribute)
                }
            }

            if cookie.isDiscardedAsInsecure {
                Label(
                    "Marked Secure but sent over plain HTTP — a browser would discard it.",
                    systemImage: "exclamationmark.triangle"
                )
                .symbolRenderingMode(.hierarchical)
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .font(.system(.callout, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics.pane)
        .padding(.vertical, Metrics.chip)
    }

    /// Flags first, because "is this Secure and HttpOnly" is the question people open this tab to
    /// answer. Session cookies say so rather than showing a blank expiry.
    private var attributes: [String] {
        var result = [cookie.domain, cookie.path]
        if cookie.isSecure { result.append("Secure") }

        if cookie.isHTTPOnly { result.append("HttpOnly") }
        if let sameSite = cookie.sameSite { result.append("SameSite=\(sameSite)") }
        result.append(
            cookie.expires.map { "Expires \($0.formatted(date: .abbreviated, time: .shortened))" }
                ?? "Session")
        return result
    }
}
