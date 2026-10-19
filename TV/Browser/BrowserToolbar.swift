import SwiftUI

enum ToolbarAction {
    case home, back, forward, reload, stop
    case favorite, theater, siteVersion, pointerSpeed, zoomIn, zoomOut, help, dismiss
    case selectTab(Int), newTab, closeTab, editAddress
}

@MainActor
final class ToolbarModel: ObservableObject {
    @Published var address = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var isFavorite = false
    @Published var isMobileSite = false
    @Published var zoomText = "100%"
    @Published var pointerSpeedName = "Normal"
    @Published var tabTitles: [String] = []
    @Published var currentTab = 0
    @Published var canAddTab = true
    /// Bumped each time the toolbar opens, to move focus back to the Back button.
    @Published var openCount = 0

    var perform: (ToolbarAction) -> Void = { _ in }
}

/// The menu across the top of a page: getting around on the first row, this page's settings on
/// the second. Hold the click to open it; it is driven by focus like the rest of tvOS.
struct BrowserToolbar: View {
    @ObservedObject var model: ToolbarModel
    @FocusState private var focused: Item?

    private enum Item: Hashable {
        case back
        case address
    }

    var body: some View {
        VStack {
            VStack(spacing: 22) {
                // Tabs.
                HStack(spacing: 14) {
                    ForEach(Array(model.tabTitles.enumerated()), id: \.offset) { index, title in
                        Button {
                            model.perform(.selectTab(index))
                        } label: {
                            Label(title, systemImage: index == model.currentTab ? "square.fill.on.square.fill" : "square.on.square")
                                .font(.callout)
                                .lineLimit(1)
                                .frame(maxWidth: 380)
                        }
                    }
                    Button {
                        model.perform(.newTab)
                    } label: {
                        Label("New Tab", systemImage: "plus")
                            .font(.callout)
                            .fixedSize()
                    }
                    .disabled(!model.canAddTab)
                    Spacer(minLength: 0)
                    labelButton("Close Tab", "xmark.square", .closeTab)
                }

                // Getting around.
                HStack(spacing: 18) {
                    iconButton("house.fill", "Home", .home)
                    iconButton("chevron.backward", "Back", .back)
                        .disabled(!model.canGoBack)
                        .focused($focused, equals: .back)
                    iconButton("chevron.forward", "Forward", .forward)
                        .disabled(!model.canGoForward)
                    if model.isLoading {
                        iconButton("xmark", "Stop", .stop)
                    } else {
                        iconButton("arrow.clockwise", "Reload", .reload)
                    }
                    Button {
                        model.perform(.editAddress)
                    } label: {
                        Label(model.address.isEmpty ? "Search or enter website" : model.address, systemImage: "magnifyingglass")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .focused($focused, equals: .address)
                }

                // This page.
                HStack(spacing: 18) {
                    labelButton(model.isFavorite ? "Favorite" : "Add Favorite",
                                model.isFavorite ? "star.fill" : "star", .favorite)
                    labelButton("Full Screen", "play.rectangle.fill", .theater)
                    labelButton(model.isMobileSite ? "Mobile Site" : "Desktop Site",
                                model.isMobileSite ? "iphone" : "desktopcomputer", .siteVersion)
                    HStack(spacing: 10) {
                        iconButton("minus.magnifyingglass", "Zoom Out", .zoomOut)
                        Text(model.zoomText)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 90)
                        iconButton("plus.magnifyingglass", "Zoom In", .zoomIn)
                    }
                    labelButton("Pointer: \(model.pointerSpeedName)", "cursorarrow.motionlines", .pointerSpeed)
                    Spacer(minLength: 0)
                    iconButton("questionmark.circle", "Remote Help", .help)
                }
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 36, style: .continuous))
            Spacer()
        }
        .padding(.horizontal, 60)
        .padding(.top, 40)
        .onExitCommand { model.perform(.dismiss) }
        .onPlayPauseCommand { model.perform(.dismiss) }
        .defaultFocus($focused, .back)
        .onChange(of: model.openCount) {
            // Start on Back, or on the address bar when there's nowhere to go back to.
            DispatchQueue.main.async { focused = model.canGoBack ? .back : .address }
        }
    }

    private func iconButton(_ symbol: String, _ label: String, _ action: ToolbarAction) -> some View {
        Button {
            model.perform(action)
        } label: {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(label)
    }

    private func labelButton(_ title: String, _ symbol: String, _ action: ToolbarAction) -> some View {
        Button {
            model.perform(action)
        } label: {
            Label(title, systemImage: symbol)
                .font(.callout)
                .lineLimit(1)
                .fixedSize()
        }
    }
}
