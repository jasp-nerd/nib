import NibCore
import SwiftUI

/// The `⌘K` request switcher.
///
/// Keyboard-only by design: type, arrow, return. The list is capped by the matcher, so it never has to
/// render more than 50 rows regardless of collection size.
public struct CommandPalette: View {
    var model: CollectionModel
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

    public init(model: CollectionModel, isPresented: Binding<Bool>) {
        self.model = model
        _isPresented = isPresented
    }

    private var matches: [FuzzyMatcher.Match] {
        FuzzyMatcher.match(query: query, in: model.fuzzyCandidates)
    }

    public var body: some View {
        VStack(spacing: 0) {
            field
            Divider()
            results
        }
        .frame(width: 560, height: 380)
        .onAppear { fieldFocused = true }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Go to request", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($fieldFocused)
                .onChange(of: query) { highlighted = 0 }
                .onSubmit(choose)
            Text("↑↓ to move · ↵ to open · esc to close")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
    }

    @ViewBuilder
    private var results: some View {
        let results = matches

        if results.isEmpty {
            VStack(spacing: 6) {
                Spacer()
                Text(query.isEmpty ? "No requests yet" : "No match for “\(query)”")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollViewReader { proxy in
                List(Array(results.enumerated()), id: \.element.id) { index, match in
                    PaletteRow(match: match, isHighlighted: index == highlighted)
                        .id(match.id)
                        .contentShape(.rect)
                        .onTapGesture {
                            highlighted = index
                            choose()
                        }
                }
                .listStyle(.plain)
                .onChange(of: highlighted) {
                    guard results.indices.contains(highlighted) else { return }
                    proxy.scrollTo(results[highlighted].id)
                }
            }
        }
    }

    // MARK: - Keyboard
    //
    // `onMoveCommand` is the macOS-only hook that gets arrow keys while a TextField holds focus. This
    // is the exact pattern SwiftUI cannot express with a focused field and a separately-navigable
    // list, and it is why the plan flags a real NSTextField for the URL bar too.

    private func move(_ direction: MoveCommandDirection) {
        let count = matches.count
        guard count > 0 else { return }
        switch direction {
        case .up: highlighted = (highlighted - 1 + count) % count
        case .down: highlighted = (highlighted + 1) % count
        default: break
        }
    }

    private func choose() {
        let results = matches
        guard results.indices.contains(highlighted) else { return }
        model.selectedRequestID = results[highlighted].id
        isPresented = false
    }
}

extension CommandPalette {
    /// Arrow-key and escape handling, attached where the modifiers can see the state.
    public func withKeyboardHandling() -> some View {
        self
            .onMoveCommand(perform: move)
            .onExitCommand { isPresented = false }
    }
}

// MARK: - Row

private struct PaletteRow: View {
    let match: FuzzyMatcher.Match
    let isHighlighted: Bool

    var body: some View {
        HStack {
            highlightedText
            Spacer()
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            isHighlighted ? Color.accentColor.opacity(0.22) : .clear,
            in: RoundedRectangle(cornerRadius: 5))
    }

    /// Bold the bytes that matched, so it is obvious *why* a result is in the list.
    ///
    /// One `AttributedString` rather than concatenated `Text` values: `Text` `+` is deprecated on
    /// macOS 26, and building a single attributed run is cheaper than a view per character anyway.
    private var highlightedText: Text {
        var attributed = AttributedString()
        let offsets = Set(match.matchedOffsets)

        // The matcher reports UTF-8 byte offsets, and the candidate text is built from names the user
        // typed, so it can contain multi-byte characters. Walking the UTF-8 view keeps the offsets
        // aligned; indexing by Character would drift on the first non-ASCII name.
        var byteIndex = 0
        for character in match.text {
            var piece = AttributedString(String(character))
            if offsets.contains(byteIndex) {
                piece.font = .body.bold()
                piece.foregroundColor = .accentColor
            }
            attributed.append(piece)
            byteIndex += String(character).utf8.count
        }

        return Text(attributed)
    }
}
