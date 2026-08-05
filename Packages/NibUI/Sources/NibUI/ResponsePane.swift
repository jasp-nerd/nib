import NibCore
import SwiftUI

/// The always-visible top strip: status, timing, size, protocol, tabs, copy.
///
/// SwiftUI hosted inside `ResponsePaneController`. Only the body itself needs to be AppKit; a
/// status pill and a segmented control gain nothing from being hand-drawn.
struct ResponseChrome: View {
    var model: AppModel
    @Bindable var state: ResponsePaneState

    private var session: RequestSession { model.session }

    var body: some View {
        VStack(spacing: 0) {
            statusRow
            // Lives in the chrome, not in the content area. The content area is covered by the
            // text view on the Body tab, which is precisely the tab where "you are only seeing the
            // first megabyte of this" needs to be readable.
            if let response = session.response, response.isTruncated, state.tab == .body,
                !session.state.isFailed
            {
                TruncationNotice(response: response)
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 12) {
            StatusSummary(session: session)
            Spacer()

            if let response = session.response, !session.state.isFailed {
                if state.tab == .body, response.isPrettyPrinted {
                    // Only offered when there is a difference to see. On a non-JSON body Pretty and
                    // Raw are the same text, and a toggle that does nothing is worse than no toggle.
                    Picker("", selection: $state.showsRaw) {
                        Text("Pretty").tag(false)
                        Text("Raw").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 130)
                }

                Picker("", selection: $state.tab) {
                    ForEach(ResponseTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)

                Button("Copy response body", systemImage: "doc.on.doc") {
                    copyBody(response)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Copy the body as it was received")
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// `bodyText`, not `displayText` — the hard-wrap newlines are a display concession and must not
    /// end up on someone's pasteboard.
    private func copyBody(_ response: ResponseViewModel) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(response.bodyText, forType: .string)
    }
}

private struct StatusSummary: View {
    var session: RequestSession

    var body: some View {
        switch session.state {
        case .sending(let received, let expected):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(Self.progressText(received: received, expected: expected))
                    .foregroundStyle(.secondary)
            }

        case .failed:
            // The message itself gets the whole pane below; repeating it here would only crowd out
            // the tabs.
            Label("Request failed", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)

        case .idle:
            if let response = session.response {
                HStack(spacing: 12) {
                    StatusPill(response: response)
                    Text(response.durationText).foregroundStyle(.secondary)
                    Text(response.sizeText).foregroundStyle(.secondary)
                    if let proto = response.networkProtocol {
                        Text(proto)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                    if !response.hops.isEmpty {
                        Text(
                            "\(response.hops.count) redirect\(response.hops.count == 1 ? "" : "s")"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("No response yet — press ⌘↩ to send.")
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private static func progressText(received: Int64, expected: Int64?) -> String {
        let receivedText = received.formatted(.byteCount(style: .binary))
        guard let expected, expected > 0 else { return "Sending… \(receivedText)" }
        return "Receiving… \(receivedText) of \(expected.formatted(.byteCount(style: .binary)))"
    }
}

private struct StatusPill: View {
    let response: ResponseViewModel

    var body: some View {
        Text("\(response.status) \(response.statusText)")
            .font(.system(.callout, design: .monospaced).weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(colour, in: RoundedRectangle(cornerRadius: 5))
    }

    private var colour: Color {
        if response.isSuccess { return .green }
        if response.isRedirect { return .orange }
        return response.isError ? .red : .secondary
    }
}

// MARK: - Everything that is not the body

/// Headers, cookies, timing, the failure panel, and the empty state.
///
/// The Body tab is deliberately absent: it is drawn by `ResponseBodyView` in AppKit, and the
/// controller hides this host while it is showing.
struct ResponseSecondaryContent: View {
    var model: AppModel
    var state: ResponsePaneState

    private var session: RequestSession { model.session }

    var body: some View {
        if case .failed(let message) = session.state {
            // A failure gets the whole pane, not a one-line label in the status bar. When a request
            // dies the status-bar version is easy to miss entirely -- it reads as "nothing
            // happened", which is the worst possible feedback for a tool whose only job is to make
            // one request and tell you what came back.
            FailureView(message: message)
        } else if let response = session.response {
            switch state.tab {
            case .body: Color.clear  // drawn by `ResponseBodyView`, in AppKit
            case .headers: HeaderList(headers: response.headers)
            case .cookies: CookieList(cookies: response.cookies)
            case .timing: TimingWaterfall(timing: response.timing, hops: response.hops)
            }
        } else {
            Color.clear
        }
    }
}

/// "You are only looking at part of this."
///
/// Says what was kept *and* what the whole thing weighs, because the difference between the two is
/// the reason a search that should have matched did not.
private struct TruncationNotice: View {
    let response: ResponseViewModel

    var body: some View {
        Label(
            "Showing the first "
                + Int64(ResponseViewModel.displayLimit).formatted(.byteCount(style: .binary))
                + " of \(response.sizeText). Copy gives you this much too.",
            systemImage: "info.circle"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.4))
    }
}

private struct FailureView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text("The request failed")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private struct HeaderList: View {
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

private struct CookieList: View {
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

private struct CookieRow: View {
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

// MARK: - Timing

/// A stacked bar of the request phases, from real `URLSessionTaskMetrics`.
///
/// DNS, connect and TLS are legitimately absent on loopback or a reused pooled connection — that is
/// information, not missing data, so those rows are simply not drawn.
struct TimingWaterfall: View {
    let timing: SendEvent.Timing
    let hops: [SendEvent.Hop]

    private var phases: [(String, Duration)] {
        [
            ("DNS", timing.dns),
            ("Connect", timing.connect),
            ("TLS", timing.tls),
            ("Request", timing.request),
            ("Waiting", timing.timeToFirstByte),
            ("Download", timing.download),
        ].compactMap { name, value in value.map { (name, $0) } }
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                let total = max(milliseconds(timing.total), 0.001)

                ForEach(phases, id: \.0) { name, duration in
                    PhaseBar(
                        name: name,
                        milliseconds: milliseconds(duration),
                        fraction: milliseconds(duration) / total)
                }

                if phases.isEmpty {
                    Text("No phase breakdown: the connection was reused or served from loopback.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }

                Divider()
                HStack(spacing: 8) {
                    Text("Total").frame(width: 90, alignment: .trailing).fontWeight(.semibold)
                    Text(String(format: "%.1f ms", milliseconds(timing.total)))
                }
                .font(.system(.callout, design: .monospaced))

                if !hops.isEmpty {
                    Divider()
                    Text("Redirects").fontWeight(.semibold)
                    ForEach(Array(hops.enumerated()), id: \.offset) { _, hop in
                        Text("\(hop.status)  \(hop.from.absoluteString) → \(hop.to.absoluteString)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(12)
        }
    }
}

/// One phase row.
///
/// Uses a proportional frame rather than a `GeometryReader` per row. A `GeometryReader` in a stack
/// row forces a layout pass to read its own size and then a second one to place the child, six
/// times over — for a bar whose width is a fraction of the container, `containerRelativeFrame`
/// says the same thing in one pass.
private struct PhaseBar: View {
    let name: String
    let milliseconds: Double
    let fraction: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(name)
                .frame(width: 90, alignment: .trailing)
                .foregroundStyle(.secondary)

            RoundedRectangle(cornerRadius: 3)
                .fill(.tint)
                .frame(height: 12)
                .containerRelativeFrame(.horizontal, alignment: .leading) { width, _ in
                    max(2, width * 0.6 * fraction)
                }

            Spacer(minLength: 0)

            Text(String(format: "%.1f ms", milliseconds))
                .frame(width: 80, alignment: .leading)
                .foregroundStyle(.secondary)
        }
        .font(.system(.callout, design: .monospaced))
    }
}
