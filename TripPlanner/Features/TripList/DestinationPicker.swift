import SwiftUI
import MapKit

/// Destination field with type-ahead suggestions and a link to destination ideas. Put it inside a
/// Form section or a List.
struct DestinationPicker: View {
    @Binding var destination: String
    @Binding var coordinate: CLLocationCoordinate2D?
    /// Called with the city name after a suggestion or idea was picked.
    var onPicked: (String) -> Void = { _ in }

    @State private var completer = DestinationCompleter()
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            TextField("Where are you going?", text: $destination)
                .focused($focused)
                .textInputAutocapitalization(.words)
                .onChange(of: destination) { _, newValue in
                    // Only typing by the user should clear the location and ask for suggestions.
                    guard focused else { return }
                    coordinate = nil
                    completer.update(newValue)
                }

            if focused {
                ForEach(completer.suggestions, id: \.self) { suggestion in
                    Button {
                        pick(suggestion)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title)
                                .foregroundStyle(.primary)
                            if !suggestion.subtitle.isEmpty {
                                Text(suggestion.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(Theme.inkSecondary)
                            }
                        }
                    }
                }
            }

            if coordinate != nil {
                Label("Location set. Search, weather and ideas will use it.", systemImage: "checkmark.seal.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.success)
            }

            NavigationLink {
                DestinationIdeasView { idea in
                    destination = idea.displayName
                    coordinate = idea.coordinate
                    completer.clear()
                    onPicked(idea.name)
                }
            } label: {
                Label("Not sure yet? Browse destination ideas", systemImage: "sparkles")
            }
        }
    }

    private func pick(_ suggestion: MKLocalSearchCompletion) {
        destination = DestinationCompleter.displayName(suggestion)
        completer.clear()
        focused = false
        onPicked(suggestion.title)
        Task {
            if let resolved = await DestinationCompleter.resolve(suggestion) {
                coordinate = resolved.coordinate
            }
        }
    }
}
