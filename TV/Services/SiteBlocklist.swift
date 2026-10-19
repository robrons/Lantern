import Foundation

/// Sites Lantern won't open: adult sites and food delivery. The browser checks every page and
/// frame a page loads, including redirects, so links, typed addresses and embedded frames are
/// all covered. Searches on Google, Bing and DuckDuckGo get SafeSearch.
enum SiteBlocklist {
    enum Category {
        case adult, foodDelivery

        var notice: String {
            switch self {
            case .adult: "Lantern blocks adult sites."
            case .foodDelivery: "Lantern blocks food delivery sites."
            }
        }
    }

    /// Whether `url` is on a blocked site, and which kind.
    static func category(of url: URL) -> Category? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty
        else { return nil }
        let labels = host.split(separator: ".").map(String.init)

        if adultTopLevelDomains.contains(labels.last ?? "")
            || labels.dropLast().contains(where: { label in adultWords.contains { label.contains($0) } })
            || matches(labels, adult) {
            return .adult
        }
        if matches(labels, foodDelivery) {
            return .foodDelivery
        }
        return nil
    }

    /// A small page saying why a site didn't open, for a tab with nothing else to show.
    static func noticePage(for category: Category) -> URL? {
        let html = """
            <!doctype html><meta charset="utf-8"><title>Blocked</title>
            <style>:root{color-scheme:light dark}body{margin:0;height:100vh;display:flex;align-items:center;\
            justify-content:center;text-align:center;font:600 40px -apple-system,sans-serif}\
            p{font-weight:400;font-size:28px;opacity:.6}</style>
            <div>\(category.notice)<p>Press Back to leave.</p></div>
            """
        let encoded = html.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return URL(string: "data:text/html;charset=utf-8," + encoded)
    }

    /// The same search with SafeSearch switched on, for searches that don't already ask for it.
    static func safeSearchURL(for url: URL) -> URL? {
        guard let host = url.host?.lowercased(),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let labels = host.split(separator: ".")
        let path = url.path
        let setting: (name: String, value: String)
        if labels.contains("google"), path == "/search" || path == "/images" {
            setting = ("safe", "active")
        } else if labels.contains("bing"), path.hasSuffix("/search") {
            setting = ("adlt", "strict")
        } else if labels.contains("duckduckgo"), components.queryItems?.contains(where: { $0.name == "q" }) == true {
            setting = ("kp", "1")
        } else {
            return nil
        }
        var items = components.queryItems ?? []
        if items.contains(where: { $0.name == setting.name && $0.value == setting.value }) {
            return nil
        }
        items.removeAll { $0.name == setting.name }
        items.append(URLQueryItem(name: setting.name, value: setting.value))
        components.queryItems = items
        return components.url
    }

    // MARK: Lists

    private struct List {
        /// Domains blocked along with their subdomains.
        var domains: Set<String> = []
        /// Names blocked under any country's domain, from lines like `deliveroo.*`.
        var anyCountry: Set<String> = []
    }

    private static let adult = load("blocked-adult")
    private static let foodDelivery = load("blocked-food-delivery")

    /// Top-level domains set aside for adult sites.
    private static let adultTopLevelDomains: Set<String> = ["xxx", "porn", "sex", "adult", "sexy"]
    /// Words that only turn up in adult sites' names, for the many sites no list keeps up with.
    private static let adultWords = [
        "porn", "xxx", "xvideo", "xnxx", "xhamster", "hentai", "nsfw", "onlyfans", "chaturbate",
        "stripchat", "redtube", "youporn", "spankbang", "brazzers", "bongacams", "livejasmin",
        "camsoda", "myfreecams",
    ]

    private static func load(_ name: String) -> List {
        var list = List()
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return list }
        for line in text.split(whereSeparator: \.isNewline) {
            let entry = line.trimmingCharacters(in: .whitespaces).lowercased()
            if entry.isEmpty || entry.hasPrefix("#") {
                continue
            }
            if entry.hasSuffix(".*") {
                list.anyCountry.insert(String(entry.dropLast(2)))
            } else {
                list.domains.insert(entry)
            }
        }
        return list
    }

    /// Whether the host or any domain above it is listed, or it's a listed name followed by a
    /// country domain such as `.fr`, `.co.uk` or `.com.au`.
    private static func matches(_ labels: [String], _ list: List) -> Bool {
        for start in labels.indices.dropLast() {
            if list.domains.contains(labels[start...].joined(separator: ".")) {
                return true
            }
            let suffix = labels[(start + 1)...]
            if list.anyCountry.contains(labels[start]),
               suffix.count == 1 || (suffix.count == 2 && ["co", "com", "net", "org"].contains(suffix.first!)) {
                return true
            }
        }
        return false
    }
}
