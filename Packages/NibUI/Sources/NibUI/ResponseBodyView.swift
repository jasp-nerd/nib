import AppKit
import NibCore

/// The response body, as a real `NSTextView` on TextKit 2.
///
/// Deliberately **not** wrapped in `NSViewRepresentable`. Two reasons, and the second is the one
/// that decided it: there are reports of TextKit 2 rendering attributes failing to draw inside a
/// representable, and a representable would have to rebuild its `NSView` in response to SwiftUI's
/// idea of when state changed rather than the text view's. Staying in AppKit the whole way down is
/// why `ResponsePaneController` exists.
///
/// ## Why the highlighting is free
///
/// Colour is applied with `setRenderingAttributes(_:for:)`, **never** by writing into the text
/// storage. Rendering attributes do not invalidate layout, so applying them cannot cascade into a
/// re-layout of the document, and they are not stored per character — which is what keeps memory
/// flat whether the body is 2 KB or 20 MB.
///
/// And only the viewport is ever touched. `JSONTokenizer` is stateless per line, so the twenty
/// lines on screen can be coloured without knowing anything about the forty thousand above them.
/// Cost is proportional to the window, not the response.
final class ResponseBodyView: NSView {

    private let scrollView = NSScrollView()
    let textView: NSTextView

    /// Turned off above `highlightLimit`, and by the caller for bodies that are not JSON.
    private var highlightingEnabled = false

    /// Above this, colouring is off by default. Not because the tokenizer is slow — it is linear
    /// and viewport-scoped — but because the pretty-printer that produces sensible lines is not,
    /// and a body this size is being skimmed rather than read.
    static let highlightLimit = 8 * 1024 * 1024

    override init(frame frameRect: NSRect) {
        textView = NSTextView(usingTextLayoutManager: true)
        super.init(frame: frameRect)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        // Nib-free app: there is no archive this could ever be decoded from.
        fatalError("ResponseBodyView is created in code")
    }

    private func setUp() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Re-colour when the viewport moves. This is the scroll view telling us it scrolled, not a
        // timer asking whether it did — the distinction the no-polling rule in CLAUDE.md is about.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(viewportMoved),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView)
    }

    deinit {
        // The observer holds an unowned reference; without this a scroll after teardown would
        // message a freed object.
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Content

    /// Replace the displayed text.
    ///
    /// `highlight` is the caller's answer to "is this JSON", which it already knows from having
    /// tried to pretty-print it. Re-detecting here would mean parsing the body a second time.
    func display(_ text: String, highlight: Bool) {
        highlightingEnabled = highlight && text.utf16.count <= Self.highlightLimit

        textView.string = text
        textView.textColor = .labelColor
        textView.scroll(.zero)

        // Lay the viewport out before colouring it.
        //
        // Not belt and braces. `viewportRange` is nil until the viewport has been laid out at least
        // once, and setting `string` invalidates it — so highlighting straight afterwards finds no
        // range and silently does nothing. The self-test did not catch this because it forces
        // layout itself; the first screenshot of the finished app did, by showing a wall of grey.
        textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        highlightViewport()
    }

    @objc private func viewportMoved() {
        // Scrolling has already laid the new viewport out; only the colours are missing.
        highlightViewport()
    }

    override func layout() {
        super.layout()
        // A resize changes which lines are in the viewport and re-wraps the ones that stay.
        textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
        highlightViewport()
    }

    // MARK: - Highlighting

    private func highlightViewport() {
        guard highlightingEnabled,
            let layoutManager = textView.textLayoutManager,
            let contentManager = layoutManager.textContentManager,
            let viewport = layoutManager.textViewportLayoutController.viewportRange
        else { return }

        // Clear first. Scrolling reuses ranges, and without this a line that changes role — a
        // string that becomes a key as you widen the window — would keep both colours.
        layoutManager.removeRenderingAttribute(.foregroundColor, for: viewport)

        contentManager.enumerateTextElements(from: viewport.location) { element in
            guard let paragraph = element as? NSTextParagraph,
                let elementRange = paragraph.elementRange
            else { return true }

            // `enumerateTextElements` runs to the end of the document unless stopped, which on a
            // 20 MB body would defeat the entire point of being viewport-scoped.
            guard elementRange.location.compare(viewport.endLocation) != .orderedDescending else {
                return false
            }

            colour(paragraph, at: elementRange.location, in: layoutManager, of: contentManager)
            return true
        }
    }

    private func colour(
        _ paragraph: NSTextParagraph,
        at start: any NSTextLocation,
        in layoutManager: NSTextLayoutManager,
        of contentManager: NSTextContentManager
    ) {
        // The paragraph's string carries its trailing newline. Handing that to the tokenizer would
        // be harmless — it produces no token — but trimming keeps "a line" meaning the same thing
        // here as it does in `JSONTokenizer`'s contract.
        var units = Array(paragraph.attributedString.string.utf16)
        while let last = units.last, last == 10 || last == 13 {
            units.removeLast()
        }
        guard !units.isEmpty else { return }

        for token in JSONTokenizer.tokens(inLine: units) {
            guard let from = contentManager.location(start, offsetBy: token.start),
                let to = contentManager.location(start, offsetBy: token.end),
                let range = NSTextRange(location: from, end: to)
            else { continue }

            layoutManager.setRenderingAttributes(
                [.foregroundColor: Self.colour(for: token.kind)], for: range)
        }
    }

    /// Whether the text view's find bar is on screen. Used by the self-test; `⌘F` is otherwise
    /// invisible to anything but a person looking at the window.
    var isFindBarVisible: Bool {
        scrollView.isFindBarVisible
    }

    // MARK: - Diagnostics

    /// Which spans are actually coloured right now.
    ///
    /// Reads back what TextKit stored rather than what we asked it to store, so a
    /// `setRenderingAttributes` call that silently no-ops shows up as an empty list rather than as
    /// a passing test. See `ResponsePaneController.bodyDiagnostics()`.
    func renderingDiagnostics() -> [String] {
        guard let layoutManager = textView.textLayoutManager else {
            return ["no text layout manager -- TextKit 1 fallback"]
        }

        // Force the viewport to lay out. In a self-test the window exists but nothing has scrolled,
        // and an un-laid-out viewport has no range to enumerate.
        layoutManager.textViewportLayoutController.layoutViewport()
        highlightViewport()

        let content = layoutManager.textContentManager
        let documentStart = layoutManager.documentRange.location
        let whole = textView.string as NSString

        var spans: [String] = []
        layoutManager.enumerateRenderingAttributes(
            from: documentStart, reverse: false
        ) { _, attributes, range in
            guard let colour = attributes[.foregroundColor] as? NSColor else { return true }

            // Offsets computed through the content manager rather than converted with an
            // `NSRange(_:in:)` initializer — the overlay advertises one but no argument label
            // actually type-checks against an `NSTextLayoutManager`, which is a good reminder that
            // the compiler catching invented APIs is not the same as the API existing.
            let start = content?.offset(from: documentStart, to: range.location) ?? 0
            let length = content?.offset(from: range.location, to: range.endLocation) ?? 0
            guard length > 0, start >= 0, start + length <= whole.length else { return true }

            spans.append(
                "\(Self.name(of: colour)):\(whole.substring(with: NSRange(location: start, length: length)))"
            )
            return spans.count < 12
        }

        return [
            "highlighting: \(highlightingEnabled ? "on" : "off")",
            "coloured spans: \(spans.count)",
            "first spans: \(spans.joined(separator: " "))",
        ]
    }

    private static func name(of colour: NSColor) -> String {
        switch colour {
        case .systemPurple: "key"
        case .systemRed: "string"
        case .systemBlue: "number"
        case .systemOrange: "literal"
        case .tertiaryLabelColor: "punct"
        default: "other"
        }
    }

    /// System colours rather than fixed hexes, so light and dark both work without a second
    /// palette and without us maintaining contrast ratios by hand.
    private static func colour(for kind: JSONTokenizer.Kind) -> NSColor {
        switch kind {
        case .key: .systemPurple
        case .string: .systemRed
        case .number: .systemBlue
        case .literal: .systemOrange
        case .punctuation: .tertiaryLabelColor
        }
    }
}
