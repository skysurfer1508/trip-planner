import SwiftUI

struct SuggestionDetailView: View {
    let place: SuggestedPlace
    let trip: Trip
    let day: Day?
    let isSaved: Bool
    let onAdd: () -> Void
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(Secrets.self) private var secrets
    @State private var detail: OTMDetail?
    @State private var added = false
    @State private var saved = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    if let url = detail?.imageURL {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Rectangle().fill(Color(.secondarySystemBackground))
                        }
                        .frame(height: 200)
                        .clipShape(Radius.shape(Radius.card))
                    }

                    Text(place.name)
                        .font(.title2.bold())

                    HStack(spacing: Spacing.m) {
                        if let rating = place.rating {
                            Label(String(format: "%.1f", rating), systemImage: "star.fill")
                                .foregroundStyle(Theme.warning)
                            if let reviews = place.reviews {
                                Text("\(reviews.formatted()) reviews")
                                    .foregroundStyle(Theme.inkSecondary)
                            }
                        }
                        Text(Format.distance(place.distance) + " away")
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    .font(.subheadline)

                    if let ranking = place.ranking {
                        Text(ranking)
                            .font(.footnote)
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    if !place.cuisines.isEmpty {
                        Text(place.cuisines.joined(separator: " · "))
                            .font(.footnote)
                    }
                    if let address = place.address ?? detail?.address {
                        Label(address, systemImage: "mappin.and.ellipse")
                            .font(.footnote)
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    if let blurb = detail?.blurb {
                        Text(blurb)
                            .font(.body)
                    }

                    AITipsSection(name: place.name, city: trip.destination)

                    VStack(spacing: Spacing.m) {
                        Button {
                            onAdd()
                            added = true
                        } label: {
                            Label(added ? "Added" : "Add to \(day.map { Format.dayChip($0.date) } ?? "day")",
                                  systemImage: added ? "checkmark" : "plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(added || day == nil)

                        Button {
                            onSave()
                            saved = true
                        } label: {
                            Label(saved ? "Saved for later" : "Save for later",
                                  systemImage: saved ? "bookmark.fill" : "bookmark")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(saved)

                        Button {
                            RoutingService.openInMaps(name: place.name, coordinate: place.coordinate, mode: .walk)
                        } label: {
                            Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)

                        if let url = place.tripadvisorURL {
                            Link(destination: url) {
                                Label("View on Tripadvisor", systemImage: "arrow.up.right.square")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                        }
                        if let url = detail?.wikipediaURL {
                            Link(destination: url) {
                                Label("Read on Wikipedia", systemImage: "book")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                        }
                    }
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { saved = isSaved }
            .task {
                if let xid = place.otmXid, secrets.hasOpenTripMap {
                    detail = await OpenTripMapService.detail(xid: xid, key: secrets.keys.openTripMap)
                }
            }
        }
        .presentationDetents([.large])
    }
}
