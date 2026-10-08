import SwiftUI

/// Curated destinations with a description and photo from Wikipedia.
struct DestinationIdeasView: View {
    let onPick: (DestinationIdea) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var tag: String?
    @State private var query = ""

    private var ideas: [DestinationIdea] {
        DestinationIdea.all.filter { idea in
            (tag == nil || idea.tags.contains(tag!))
                && (query.isEmpty
                    || idea.name.localizedCaseInsensitiveContains(query)
                    || idea.country.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.s) {
                        FilterChip(title: "All", isOn: tag == nil) { tag = nil }
                        ForEach(DestinationIdea.tags, id: \.self) { t in
                            FilterChip(title: t, isOn: tag == t) { tag = (tag == t) ? nil : t }
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
            .listRowBackground(Color.clear)

            ForEach(ideas) { idea in
                Button {
                    onPick(idea)
                    dismiss()
                } label: {
                    IdeaRow(idea: idea)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Where to go")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search destinations")
        .overlay {
            if ideas.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }
}

private struct IdeaRow: View {
    let idea: DestinationIdea
    @State private var summary: WikiSummary?

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            AsyncImage(url: summary?.thumbnail) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(Color(.secondarySystemBackground))
                    .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
            }
            .frame(width: 72, height: 72)
            .clipShape(Radius.shape(Radius.small))

            VStack(alignment: .leading, spacing: 3) {
                Text(idea.name)
                    .font(.headline)
                Text(idea.country)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let extract = summary?.extract, !extract.isEmpty {
                    Text(extract)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Text(idea.tags.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, Spacing.xs)
        .task { summary = await WikipediaService.summary(title: idea.wikiTitle) }
    }
}
