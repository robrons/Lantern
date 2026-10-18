import Foundation

enum URLInput {
    /// Turns what someone typed into a URL: a full address, a bare domain, or a web search.
    static func resolve(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme), url.host != nil {
            return url
        }

        let looksLikeAddress = !trimmed.contains(" ")
            && (trimmed.contains(".") || trimmed.hasPrefix("localhost"))
        if looksLikeAddress, let url = URL(string: "https://" + trimmed), url.host != nil {
            return url
        }

        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components.url
    }
}
