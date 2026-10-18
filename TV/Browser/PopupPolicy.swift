import Foundation

/// Which windows a page may open. Sign-in windows and windows from the same site open; other
/// windows opened by scripts are almost always ads and stay blocked.
enum PopupPolicy {
    /// Sites whose sign-in windows other sites open ("Sign in with Google", and so on).
    private static let signInHosts = [
        "accounts.google.com",
        "appleid.apple.com",
        "login.microsoftonline.com",
        "login.live.com",
        "github.com",
        "facebook.com",
        "auth.openai.com",
        "discord.com",
        "x.com",
        "twitter.com",
    ]

    static func allows(_ url: URL, openedFrom opener: URL?) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if signInHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return true
        }
        guard let openerHost = opener?.host?.lowercased() else { return false }
        return siteName(host) == siteName(openerHost)
    }

    /// The part of a host name a site owns: "chatgpt.com" for "auth.chatgpt.com", and
    /// "bbc.co.uk" for "www.bbc.co.uk".
    static func siteName(_ host: String) -> String {
        let labels = host.split(separator: ".")
        guard labels.count > 2 else { return host }
        let secondLevel = ["co", "com", "org", "net", "ac", "gov", "edu"]
        let keep = labels.last!.count == 2 && secondLevel.contains(String(labels[labels.count - 2])) ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }
}
