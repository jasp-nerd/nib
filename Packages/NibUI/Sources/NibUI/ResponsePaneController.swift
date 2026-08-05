import AppKit
import Observation
import SwiftUI

/// The response pane: SwiftUI chrome on top, and for the Body tab a real `NSTextView` underneath.
///
/// This controller exists for one reason — the body has to be genuine AppKit, not a view wrapped in
/// `NSViewRepresentable` (see `ResponseBodyView`). Everything else in the pane is still SwiftUI,
/// hosted in an `NSHostingView`, because a status pill and a table of headers gain nothing from
/// being hand-drawn.
///
/// The split is: chrome always visible, content swapped per tab. Only the Body tab gets the text
/// view, and it is created once and reused rather than rebuilt per response — building an
/// `NSTextView` is not free, and the pane is the thing you look at after every single send.
public final class ResponsePaneController: NSViewController {

    private let model: AppModel
    private let state = ResponsePaneState()

    private let chromeHost: NSHostingView<ResponseChrome>
    private var contentHost: NSHostingView<ResponseSecondaryContent>?
    private let bodyView = ResponseBodyView()

    /// What the text view currently shows, so an unrelated redraw does not re-push a megabyte of
    /// text into it. `NSTextView.string =` is not cheap and it drops the selection.
    private var displayedBodyIdentity: BodyIdentity?

    private struct BodyIdentity: Equatable {
        let responseID: UUID
        let showsRaw: Bool
    }

    public init(model: AppModel) {
        self.model = model
        let state = self.state
        chromeHost = NSHostingView(rootView: ResponseChrome(model: model, state: state))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ResponsePaneController is created in code")
    }

    public override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false

        chromeHost.translatesAutoresizingMaskIntoConstraints = false
        bodyView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(chromeHost)
        view.addSubview(bodyView)

        NSLayoutConstraint.activate([
            chromeHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chromeHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chromeHost.topAnchor.constraint(equalTo: view.topAnchor),

            bodyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bodyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bodyView.topAnchor.constraint(equalTo: chromeHost.bottomAnchor),
            bodyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        refresh()
        observe()
    }

    // MARK: - Observation
    //
    // The AppKit half of the app has to react to `@Observable` changes without a Combine
    // subscription and without polling. `withObservationTracking` fires its `onChange` once, before
    // the change is applied, so the pattern is: hop to the next main-actor turn, refresh, and
    // re-arm. Forgetting to re-arm gives you a pane that updates exactly once, which is a very
    // convincing impression of a frozen UI.

    private func observe() {
        withObservationTracking {
            _ = model.session.response
            _ = model.session.state
            _ = state.tab
            _ = state.showsRaw
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                refresh()
                observe()
            }
        }
    }

    // MARK: - Content

    private func refresh() {
        let showsBody =
            state.tab == .body && model.session.response != nil
            && model.session.state.isFailed == false

        bodyView.isHidden = !showsBody
        if showsBody {
            updateBodyText()
        } else {
            showSecondaryContent()
        }
    }

    private func updateBodyText() {
        guard let response = model.session.response else { return }

        let identity = BodyIdentity(responseID: response.id, showsRaw: state.showsRaw)
        guard identity != displayedBodyIdentity else { return }
        displayedBodyIdentity = identity

        // Raw shows exactly what arrived; Pretty shows the reformatted text. Both are hard-wrapped,
        // because a single unbroken 4 MB line stalls layout in either mode.
        let text =
            state.showsRaw
            ? ResponseViewModel.hardWrapping(response.rawText, at: ResponseViewModel.hardWrapWidth)
            : response.displayText

        bodyView.display(text, highlight: response.looksLikeJSON)
        contentHost?.isHidden = true
    }

    private func showSecondaryContent() {
        displayedBodyIdentity = nil

        let content = ResponseSecondaryContent(model: model, state: state)
        if let host = contentHost {
            host.rootView = content
            host.isHidden = false
            return
        }

        let host = NSHostingView(rootView: content)
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.topAnchor.constraint(equalTo: chromeHost.bottomAnchor),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        contentHost = host
    }

    // MARK: - Find

    /// `⌘F`, routed from the menu.
    ///
    /// Uses the text view's own find bar rather than a hand-rolled one: it already does incremental
    /// match highlighting, wrap-around, and `⌘G`, and it looks like every other macOS app.
    public func showFindBar() {
        guard state.tab == .body, model.session.response != nil else { return }
        view.window?.makeFirstResponder(bodyView.textView)
        bodyView.textView.performFindPanelAction(
            NSMenuItem(
                title: "", action: nil, keyEquivalent: ""
            ).withTag(NSTextFinder.Action.showFindInterface.rawValue))
    }

    public var canFind: Bool {
        state.tab == .body && model.session.response != nil
    }

    // MARK: - Diagnostics

    /// What the body pane is actually rendering, for `NIB_SELFTEST_BODY`.
    ///
    /// Worth a public method on a view controller because the claim being checked cannot be checked
    /// any other way: "the highlighter applies colour" is invisible to a unit test — `JSONTokenizer`
    /// can be right while `setRenderingAttributes` silently does nothing in this particular view
    /// configuration, which is precisely the failure mode reported for TextKit 2 inside
    /// `NSViewRepresentable`. Only the assembled, running view can answer it.
    public func bodyDiagnostics() -> [String] {
        var lines = ["body chars: \(bodyView.textView.string.utf16.count)"]
        lines.append("body hidden: \(bodyView.isHidden)")
        lines.append(contentsOf: bodyView.renderingDiagnostics())

        // `⌘F` goes through `performFindPanelAction` with a synthesized sender whose tag carries
        // the action. That is easy to get subtly wrong -- a wrong tag is silently ignored -- so the
        // check is whether the bar actually appeared, not whether the call returned.
        showFindBar()
        lines.append("find bar visible: \(bodyView.isFindBarVisible)")
        return lines
    }
}

/// Tab selection and the Pretty/Raw toggle.
///
/// Its own `@Observable` object rather than `@State` in a view, because both the SwiftUI chrome and
/// the AppKit controller read it — a `@State` would be private to one of them.
@Observable
final class ResponsePaneState {
    var tab: ResponseTab = .body
    var showsRaw = false
}

enum ResponseTab: String, CaseIterable, Identifiable {
    case body = "Body"
    case headers = "Headers"
    case cookies = "Cookies"
    case timing = "Timing"

    var id: String { rawValue }
}

extension NSMenuItem {
    /// `performFindPanelAction` reads the sender's tag and nothing else.
    fileprivate func withTag(_ value: Int) -> NSMenuItem {
        tag = value
        return self
    }
}
