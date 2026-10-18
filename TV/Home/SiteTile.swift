import SwiftUI
import UIKit

/// A site on the home screen: a snapshot of the page if Lantern has one, otherwise its icon.
struct SiteTile: View {
    let site: Site
    @ObservedObject var library: Library
    var width: CGFloat = 400
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button(action: action) {
                preview
                    .frame(width: width, height: width * 9 / 16)
            }
            .buttonStyle(.card)

            VStack(alignment: .leading, spacing: 4) {
                Text(site.displayTitle)
                    .font(.callout)
                    .lineLimit(1)
                Text(site.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
        }
    }

    @ViewBuilder
    private var preview: some View {
        // Reading the revision redraws the tile when a new snapshot is saved.
        let _ = library.snapshotRevision
        if let snapshot = library.snapshot(for: site.url) {
            Image(uiImage: snapshot)
                .resizable()
                .scaledToFill()
                .frame(width: width, height: width * 9 / 16, alignment: .top)
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    SiteIcon(site: site, size: 64)
                        .shadow(radius: 6)
                        .padding(18)
                }
        } else {
            ZStack {
                LinearGradient(colors: SiteColors.colors(for: site.host), startPoint: .topLeading, endPoint: .bottomTrailing)
                SiteIcon(site: site, size: width * 0.28)
                    .shadow(radius: 10)
            }
        }
    }
}

struct SiteIcon: View {
    let site: Site
    let size: CGFloat
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Color.white
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Color.white.opacity(0.18)
                Text(site.host.prefix(1).uppercased())
                    .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .task(id: site.id) {
            image = await IconLoader.shared.icon(for: site)
        }
    }
}

/// Fetches site icons, trying the page's declared icon and then the usual locations.
actor IconLoader {
    static let shared = IconLoader()

    private var cache: [String: UIImage] = [:]
    private var missing: Set<String> = []

    func icon(for site: Site) async -> UIImage? {
        let key = site.host
        if let cached = cache[key] { return cached }
        if missing.contains(key) { return nil }

        var candidates: [URL] = []
        if let declared = site.iconURL { candidates.append(declared) }
        if let scheme = site.url.scheme, let host = site.url.host {
            candidates.append(URL(string: "\(scheme)://\(host)/apple-touch-icon.png")!)
            candidates.append(URL(string: "\(scheme)://\(host)/favicon.ico")!)
        }

        for url in candidates {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data), image.size.width >= 16
            else { continue }
            cache[key] = image
            return image
        }
        missing.insert(key)
        return nil
    }
}

enum SiteColors {
    private static let palettes: [[Color]] = [
        [Color(red: 0.98, green: 0.36, blue: 0.35), Color(red: 0.75, green: 0.16, blue: 0.36)],
        [Color(red: 0.25, green: 0.55, blue: 0.98), Color(red: 0.31, green: 0.24, blue: 0.79)],
        [Color(red: 0.18, green: 0.75, blue: 0.62), Color(red: 0.07, green: 0.45, blue: 0.55)],
        [Color(red: 0.99, green: 0.66, blue: 0.24), Color(red: 0.89, green: 0.33, blue: 0.18)],
        [Color(red: 0.63, green: 0.42, blue: 0.96), Color(red: 0.36, green: 0.20, blue: 0.69)],
        [Color(red: 0.36, green: 0.40, blue: 0.47), Color(red: 0.16, green: 0.18, blue: 0.23)],
    ]

    static func colors(for host: String) -> [Color] {
        let hash = host.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palettes[hash % palettes.count]
    }
}
