import SwiftUI

@MainActor
final class Router: ObservableObject {
    /// The page open in the browser, shown as the Continue tile.
    @Published var currentPage: Site?

    var openURL: (URL) -> Void = { _ in }
    var resume: () -> Void = {}

    func open(text: String) {
        if let url = URLInput.resolve(text) { openURL(url) }
    }
}

struct HomeView: View {
    @ObservedObject var library: Library
    @ObservedObject var router: Router
    @State private var query = ""
    /// Set after one Back press; a second Back within a moment leaves Lantern.
    @State private var leaveArmed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 60) {
                    header

                    if let page = router.currentPage {
                        Shelf(title: "Continue") {
                            SiteTile(site: page, library: library, width: 560) { router.resume() }
                        }
                    }

                    if !library.favorites.isEmpty {
                        Shelf(title: "Favorites") {
                            ForEach(library.favorites) { site in
                                SiteTile(site: site, library: library) { router.openURL(site.url) }
                                    .contextMenu {
                                        Button("Remove from Favorites", role: .destructive) {
                                            library.removeFavorite(site)
                                        }
                                    }
                            }
                        }
                    }

                    if !library.recent.isEmpty {
                        Shelf(title: "Recently Visited") {
                            ForEach(library.recent) { site in
                                SiteTile(site: site, library: library) { router.openURL(site.url) }
                                    .contextMenu {
                                        if !library.isFavorite(site.url) {
                                            Button("Add to Favorites") { library.addFavorite(site) }
                                        }
                                        Button("Remove from History", role: .destructive) {
                                            library.removeFromHistory(site)
                                        }
                                    }
                            }
                        }
                    }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 50)
            }
            // With no handler, Back does its usual job of leaving the app.
            .onExitCommand(perform: leaveArmed ? nil : armLeave)
            .overlay(alignment: .bottom) {
                if leaveArmed {
                    Text("Press Back again to leave Lantern")
                        .font(.callout)
                        .padding(.horizontal, 36)
                        .padding(.vertical, 18)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 60)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: leaveArmed)
        }
    }

    private func armLeave() {
        leaveArmed = true
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            leaveArmed = false
        }
    }

    private var header: some View {
        HStack(spacing: 40) {
            Label {
                Text("Lantern")
            } icon: {
                Image("LanternGlyph")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 52, height: 52)
                    .foregroundStyle(.orange)
            }
            .font(.title2.bold())
            .labelStyle(.titleAndIcon)
            TextField("Search or enter website", text: $query)
                .onSubmit {
                    router.open(text: query)
                    query = ""
                }
            NavigationLink {
                HistoryView(library: library) { router.openURL($0) }
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
        }
    }
}

private struct Shelf<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 48) {
                    content
                }
                .padding(.vertical, 30)
            }
            .scrollClipDisabled()
        }
    }
}
