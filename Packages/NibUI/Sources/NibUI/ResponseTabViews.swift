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
            VStack(spacing: 6) {
                Text("No history yet").font(.headline)
                Text("Responses to this request will be listed here, newest first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                Text("\(entry.status)")
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(colour, in: RoundedRectangle(cornerRadius: 4))

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
                .padding(8)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))

                if entry.isBodyTruncated {
                    Text("Preview only — history keeps the first 64 KB.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var colour: Color {
        switch entry.status {
        case 200..<300: .green
        case 300..<400: .orange
        case 400...: .red
        default: .secondary
        }
    }
}

struct HeaderList: View {
    let headers: [SendPlan.Header]

    var body: some View {
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
            VStack(spacing: 6) {
                Text("No cookies").font(.headline)
                Text("Nothing in this response set one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            HStack(spacing: 6) {
                ForEach(attributes, id: \.self) { attribute in
                    Text(attribute)
                        .font(.caption)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                }
            }

            if cookie.isDiscardedAsInsecure {
                Label(
                    "Marked Secure but sent over plain HTTP — a browser would discard it.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .font(.system(.callout, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
