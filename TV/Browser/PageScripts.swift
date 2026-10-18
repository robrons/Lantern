import CoreGraphics
import Foundation

/// The JavaScript Lantern injects into pages, and helpers for calling into it.
enum PageScripts {
    /// Lets Lantern's scripts in different frames recognise each other's messages.
    private static let token = UUID().uuidString

    static let isolated = load("lantern-isolated").replacingOccurrences(of: "__LANTERN_TOKEN__", with: token)
    static let page = load("lantern-page")

    private static func load(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else {
            assertionFailure("Missing \(name).js")
            return ""
        }
        return source
    }

    /// A call to `window.__lantern.<function>(...)` with the arguments encoded as JavaScript.
    static func call(_ function: String, _ arguments: Any...) -> String {
        let encoded = arguments.map(encode).joined(separator: ", ")
        return "window.__lantern && window.__lantern.\(function)(\(encoded))"
    }

    private static func encode(_ value: Any) -> String {
        switch value {
        case let bool as Bool:
            return bool ? "true" : "false"
        case let number as CGFloat:
            return number.isFinite ? "\(Double(number))" : "0"
        case let number as Double:
            return number.isFinite ? "\(number)" : "0"
        case let number as Int:
            return "\(number)"
        case let string as String:
            let data = (try? JSONSerialization.data(withJSONObject: [string])) ?? Data("[\"\"]".utf8)
            return String(decoding: data, as: UTF8.self).dropFirst().dropLast().description
        default:
            return "null"
        }
    }
}

enum ContentRules {
    /// Blocks every request to the domains in blocked-domains.txt, and their subdomains.
    static let blockedDomains: String = {
        guard let url = Bundle.main.url(forResource: "blocked-domains", withExtension: "txt"),
              let list = try? String(contentsOf: url, encoding: .utf8)
        else { return "[]" }
        let rules: [[String: Any]] = list.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { domain in
                let pattern = NSRegularExpression.escapedPattern(for: domain.lowercased())
                return [
                    "trigger": ["url-filter": "^[a-z]+://([^/:]+\\.)?\(pattern)[:/]"],
                    "action": ["type": "block"],
                ]
            }
        let data = (try? JSONSerialization.data(withJSONObject: rules)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }()
}

enum UserAgent {
    /// Safari on a Mac, so sites send their full desktop experience.
    static let desktopSafari = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    /// Safari on an iPhone. Sites send iPhones video in Apple's HLS format, which the TV can play.
    static let iPhoneSafari = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1"
}
