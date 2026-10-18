import SwiftUI

struct HistoryView: View {
    @ObservedObject var library: Library
    let open: (URL) -> Void
    @State private var confirmingClear = false

    var body: some View {
        List {
            if library.history.isEmpty {
                Text("Pages you visit will show up here.")
                    .foregroundStyle(.secondary)
            } else {
                Button("Clear History…", role: .destructive) { confirmingClear = true }
            }

            ForEach(library.history) { site in
                Button {
                    open(site.url)
                } label: {
                    HStack(spacing: 28) {
                        SiteIcon(site: site, size: 60)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(site.displayTitle)
                                .lineLimit(1)
                            Text(site.host)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(site.visited, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contextMenu {
                    if !library.isFavorite(site.url) {
                        Button("Add to Favorites") { library.addFavorite(site) }
                    }
                    Button("Remove from History", role: .destructive) { library.removeFromHistory(site) }
                }
            }
        }
        .navigationTitle("History")
        .confirmationDialog("Clear all history?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) { library.clearHistory() }
        }
    }
}
