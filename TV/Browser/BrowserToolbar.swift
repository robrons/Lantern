import SwiftUI

enum ToolbarAction {
    case home, back, forward, reload, stop
    case open(String)
    case favorite, theater, siteVersion, pointerSpeed, zoomIn, zoomOut, help, dismiss
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
        case other
    }

    var body: some View {
        VStack {
            VStack(spacing: 22) {
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
                    TextField("Search or enter website", text: $model.address)
                        .onSubmit { model.perform(.open(model.address)) }
                        .frame(maxWidth: .infinity)
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
            DispatchQueue.main.async { focused = model.canGoBack ? .back : nil }
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
