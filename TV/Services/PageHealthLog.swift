import Foundation

/// A short record, kept on the TV, of pages whose process stopped and why, so problems can be
/// looked into afterwards. Holds the last 200 entries.
enum PageHealthLog {
    private static let key = "pageHealth"
    private static let limit = 200

    static func record(_ event: String, url: URL?, detail: String) {
        var entries = UserDefaults.standard.array(forKey: key) as? [[String: String]] ?? []
        entries.append([
            "time": Date().formatted(date: .numeric, time: .standard),
            "event": event,
            "url": url?.absoluteString ?? "",
            "detail": detail,
        ])
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
        UserDefaults.standard.set(entries, forKey: key)
    }
}
