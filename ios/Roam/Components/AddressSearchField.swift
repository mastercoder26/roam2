import MapKit
import SwiftUI

struct AddressSearchField: View {
    @ObservedObject private var theme = ThemeManager.shared
    let title: String
    let placeholder: String
    let systemImage: String
    var iconColor: Color = .secondary
    var showsIcon = true
    var maximumSuggestions = 2
    @Binding var text: String
    var onSuggestionsVisibilityChanged: ((Bool) -> Void)?

    @StateObject private var completer = AddressSearchCompleter()
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showSuggestions: Bool {
        isFocused && !completer.suggestions.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AppDesign.space12) {
                if showsIcon {
                    Image(systemName: systemImage)
                        .font(.caption)
                        .foregroundStyle(iconColor)
                        .frame(width: 20)
                }

                TextField(placeholder, text: $text)
                    .focused($isFocused)
                    .font(AppDesign.Typography.body)
                    .foregroundStyle(AppDesign.Ink.primary)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .onChange(of: text) { _, newValue in
                        completer.queryFragment = newValue
                    }
            }
            .padding(.vertical, 6)

            if showSuggestions {
                Divider()
                    .padding(.leading, showsIcon ? 32 : 0)
                    .transition(.opacity)

                ForEach(Array(completer.suggestions.prefix(maximumSuggestions).enumerated()), id: \.offset) { _, suggestion in
                    Button {
                        text = suggestion.title + (suggestion.subtitle.isEmpty ? "" : ", \(suggestion.subtitle)")
                        completer.clear()
                        isFocused = false
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title)
                                .font(.body)
                                .foregroundStyle(AppDesign.Ink.primary)
                            if !suggestion.subtitle.isEmpty {
                                Text(suggestion.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(AppDesign.Ink.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 7)
                        .padding(.leading, showsIcon ? 32 : 0)
                    }
                    .buttonStyle(.plain)
                }
                .transition(.opacity)
            }
        }
        .animation(suggestionAnimation, value: showSuggestions)
        .onChange(of: showSuggestions) { _, isVisible in
            onSuggestionsVisibilityChanged?(isVisible)
        }
        .onDisappear {
            onSuggestionsVisibilityChanged?(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    /// High-frequency interaction — opacity only, no slide (Emil: keyboard-adjacent = minimal motion)
    private var suggestionAnimation: Animation? {
        reduceMotion ? nil : AppAnimation.quick
    }
}

@MainActor
final class AddressSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var suggestions: [MKLocalSearchCompletion] = []

    private let completer = MKLocalSearchCompleter()

    var queryFragment: String = "" {
        didSet {
            completer.queryFragment = queryFragment
        }
    }

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = .address
    }

    func clear() {
        suggestions = []
        completer.queryFragment = ""
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        Task { @MainActor in
            suggestions = completer.results
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            suggestions = []
        }
    }
}
