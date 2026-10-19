import CryptoKit
import UIKit

struct Site: Codable, Identifiable, Hashable {
    var url: URL
    var title: String
    var iconURL: URL?
    var visited: Date

    var id: String { Library.key(for: url) }

    var host: String {
        guard let host = url.host else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var displayTitle: String { title.isEmpty ? host : title }
}

/// Favorites, history and page snapshots. tvOS apps can't rely on files surviving, so the
/// lists live in UserDefaults and snapshots in the caches folder, where losing them is harmless.
@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published private(set) var favorites: [Site] = []
    @Published private(set) var history: [Site] = []
    /// Bumped when a snapshot is saved, so tiles showing it redraw.
    @Published private(set) var snapshotRevision = 0

    private let defaults = UserDefaults.standard
    private let historyLimit = 200
    /// Recently shown snapshots. Capped, and emptied when memory runs low.
    private let snapshotCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 24
        return cache
    }()
    private let snapshotFolder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let folder = caches.appendingPathComponent("Snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    private enum Keys {
        static let favorites = "favorites"
        static let history = "history"
        static let seeded = "seededFavorites"
        static let mobileHosts = "mobileHosts"
        static let addedMobileHosts = "addedMobileHosts"
        static let siteZooms = "siteZooms"
    }

    init() {
        favorites = decode(Keys.favorites)
        history = decode(Keys.history)
        mobileHosts = (defaults.stringArray(forKey: Keys.mobileHosts)).map(Set.init) ?? Self.defaultMobileHosts
        // Sites added to the defaults later are added once, so switching one back to its desktop
        // version afterwards sticks.
        let added = Set(defaults.stringArray(forKey: Keys.addedMobileHosts) ?? [])
        mobileHosts.formUnion(Self.defaultMobileHosts.subtracting(added))
        defaults.set(Array(Self.defaultMobileHosts), forKey: Keys.addedMobileHosts)
        defaults.set(Array(mobileHosts), forKey: Keys.mobileHosts)
        if !defaults.bool(forKey: Keys.seeded) {
            favorites = Self.starterFavorites
            defaults.set(true, forKey: Keys.seeded)
            save()
        }
    }

    /// Ignores the fragment and a trailing slash, so `example.com/` and `example.com/#top` match.
    nonisolated static func key(for url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        var string = components?.string ?? url.absoluteString
        if string.hasSuffix("/") { string.removeLast() }
        return string
    }

    var recent: [Site] { Array(history.prefix(20)) }

    func recordVisit(url: URL, title: String, iconURL: URL?) {
        let key = Self.key(for: url)
        var site = history.first { $0.id == key } ?? Site(url: url, title: title, iconURL: iconURL, visited: Date())
        site.url = url
        site.visited = Date()
        if !title.isEmpty { site.title = title }
        if let iconURL { site.iconURL = iconURL }
        history.removeAll { $0.id == key }
        history.insert(site, at: 0)
        if history.count > historyLimit {
            history.removeLast(history.count - historyLimit)
        }

        if let index = favorites.firstIndex(where: { $0.id == key }) {
            if favorites[index].iconURL == nil { favorites[index].iconURL = iconURL }
            if favorites[index].title.isEmpty { favorites[index].title = title }
        }
        save()
    }

    func isFavorite(_ url: URL) -> Bool {
        let key = Self.key(for: url)
        return favorites.contains { $0.id == key }
    }

    func toggleFavorite(url: URL, title: String, iconURL: URL?) {
        let key = Self.key(for: url)
        if favorites.contains(where: { $0.id == key }) {
            favorites.removeAll { $0.id == key }
        } else {
            favorites.append(Site(url: url, title: title, iconURL: iconURL, visited: Date()))
        }
        save()
    }

    func addFavorite(_ site: Site) {
        guard !favorites.contains(where: { $0.id == site.id }) else { return }
        favorites.append(site)
        save()
    }

    func removeFavorite(_ site: Site) {
        favorites.removeAll { $0.id == site.id }
        save()
    }

    func removeFromHistory(_ site: Site) {
        history.removeAll { $0.id == site.id }
        save()
    }

    func clearHistory() {
        history.removeAll()
        save()
    }

    // MARK: Site versions

    /// Sites to open in their iPhone version. The TV can't play the streaming format most
    /// desktop sites use, but it plays the HLS video sites send iPhones.
    private(set) var mobileHosts: Set<String> = []
    /// YouTube's mobile site sends video the TV can play; LinkedIn's desktop feed crashes the
    /// TV's web engine, while its mobile site works.
    private static let defaultMobileHosts: Set<String> = ["youtube.com", "linkedin.com"]

    func prefersMobileSite(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return mobileHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func setPrefersMobileSite(_ mobile: Bool, for url: URL) {
        guard var host = url.host?.lowercased() else { return }
        if let existing = mobileHosts.first(where: { host == $0 || host.hasSuffix("." + $0) }) {
            host = existing
        } else if host.hasPrefix("www.") || host.hasPrefix("m.") {
            host = String(host.drop(while: { $0 != "." }).dropFirst())
        }
        if mobile { mobileHosts.insert(host) } else { mobileHosts.remove(host) }
        defaults.set(Array(mobileHosts), forKey: Keys.mobileHosts)
    }

    // MARK: Zoom

    /// Page zoom per site. Sites start at 100% and keep whatever you change them to.
    private lazy var siteZooms: [String: Double] =
        defaults.dictionary(forKey: Keys.siteZooms) as? [String: Double] ?? [:]

    func zoom(for url: URL) -> CGFloat {
        guard let site = Self.siteKey(for: url) else { return 1 }
        return CGFloat(siteZooms[site] ?? 1)
    }

    func setZoom(_ zoom: CGFloat, for url: URL) {
        guard let site = Self.siteKey(for: url) else { return }
        siteZooms[site] = zoom == 1 ? nil : Double(zoom)
        defaults.set(siteZooms, forKey: Keys.siteZooms)
    }

    /// A site's name without "www." or "m.", so its desktop and mobile pages share settings.
    private static func siteKey(for url: URL) -> String? {
        guard var host = url.host?.lowercased() else { return nil }
        for prefix in ["www.", "m."] where host.hasPrefix(prefix) {
            host.removeFirst(prefix.count)
        }
        return host
    }

    // MARK: Snapshots

    func snapshot(for url: URL) -> UIImage? {
        let key = Self.key(for: url)
        if let cached = snapshotCache.object(forKey: key as NSString) { return cached }
        guard let image = UIImage(contentsOfFile: snapshotFile(for: key).path) else { return nil }
        snapshotCache.setObject(image, forKey: key as NSString)
        return image
    }

    func saveSnapshot(_ image: UIImage, for url: URL) {
        let key = Self.key(for: url)
        snapshotCache.setObject(image, forKey: key as NSString)
        snapshotRevision += 1
        guard let data = image.jpegData(compressionQuality: 0.7) else { return }
        try? data.write(to: snapshotFile(for: key), options: .atomic)
    }

    /// Frees snapshots held in memory; they reload from disk when shown again.
    func clearMemoryCaches() {
        snapshotCache.removeAllObjects()
    }

    private func snapshotFile(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return snapshotFolder.appendingPathComponent(digest).appendingPathExtension("jpg")
    }

    // MARK: Storage

    private func decode(_ key: String) -> [Site] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Site].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        defaults.set(try? encoder.encode(favorites), forKey: Keys.favorites)
        defaults.set(try? encoder.encode(history), forKey: Keys.history)
    }

    private static let starterFavorites: [Site] = [
        ("https://www.youtube.com", "YouTube"),
        ("https://archive.org/details/feature_films", "Internet Archive Films"),
        ("https://vimeo.com/watch", "Vimeo"),
        ("https://www.wikipedia.org", "Wikipedia"),
    ].map { Site(url: URL(string: $0.0)!, title: $0.1, iconURL: nil, visited: Date()) }
}
