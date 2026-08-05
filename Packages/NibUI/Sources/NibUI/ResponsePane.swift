import NibCore
import NibStore
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

            if session.response != nil || !model.history.isEmpty {
                if let response = session.response, state.tab == .body, response.isPrettyPrinted,
                    !session.state.isFailed
                {
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
                .frame(width: 330)

                if let response = session.response {
                    Button("Copy response body", systemImage: "doc.on.doc") {
                        copyBody(response)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Copy the body as it was received")
                }
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
                HStack(spacing: Metrics.pane) {
                    StatusPill(response: response)
                    // Monospaced digits so "9.8 ms" becoming "148.2 ms" does not shove the size and
                    // the protocol badge sideways, and a numeric-text transition so the number
                    // rolls to its new value in place instead of being replaced.
                    Text(response.durationText)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(response.sizeText)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    if let proto = response.networkProtocol {
                        Badge(text: proto)
                            .help("Negotiated protocol")
                    }
                    if !response.hops.isEmpty {
                        Text(
                            "\(response.hops.count) redirect\(response.hops.count == 1 ? "" : "s")"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
                .animation(.smooth(duration: 0.2), value: response.id)
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
        Badge(
            text: "\(response.status) \(response.statusText)",
            prominence: .filled,
            tint: StatusStyle.colour(for: response.status)
        )
        // The colour says client-error-versus-server-error faster than the number does, and it is
        // the one thing a screen reader cannot see. Say it.
        .accessibilityLabel(
            "\(StatusStyle.label(for: response.status)): "
                + "\(response.status) \(response.statusText)"
        )
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
            FailureView(message: message, failure: session.failure, session: session)
        } else if state.tab == .history {
            HistoryList(model: model)
        } else if let response = session.response {
            switch state.tab {
            case .body: Color.clear  // drawn by `ResponseBodyView`, in AppKit
            case .headers: HeaderList(headers: response.headers)
            case .cookies: CookieList(cookies: response.cookies)
            case .timing: TimingWaterfall(timing: response.timing, hops: response.hops)
            case .history: HistoryList(model: model)
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
        Banner(severity: .info) {
            Text(
                "Showing the first "
                    + Int64(ResponseViewModel.displayLimit).formatted(.byteCount(style: .binary))
                    + " of \(response.sizeText). Copy gives you this much too."
            )
        }
    }
}

private struct FailureView: View {
    let message: String
    let failure: SendEvent.Failure?
    var session: RequestSession

    private var tlsReason: String? {
        if case .tlsUntrusted(let reason) = failure?.kind { return reason }
        return nil
    }

    var body: some View {
        ContentUnavailableView {
            Label(
                tlsReason == nil
                    ? "The request failed" : "The server's certificate was rejected",
                systemImage: tlsReason == nil
                    ? "exclamationmark.triangle.fill" : "lock.trianglebadge.exclamationmark"
            )
            // Hierarchical keeps the badge on the lock glyph legible at empty-state size; flat
            // orange turns it into a single silhouette.
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.orange)
        } description: {
            Text(tlsReason ?? message)
                .textSelection(.enabled)
        } actions: {
            if tlsReason != nil {
                // The reason this panel exists. `-1202` with nothing to click is where people give
                // up on a client and go back to curl -k.
                Button("Retry without verifying the certificate") {
                    session.retryWithoutTLSVerification()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text(
                    "Turns verification off for this request only, and saves it with the request "
                        + "so it stays visible in your diff."
                )
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
