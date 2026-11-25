import Foundation

enum Engine: String, CaseIterable, Identifiable {
    case google, duckduckgo, bing, ecosia, startpage, kagi, brave, qwant, custom

    static let standard = Engine.google

    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: return "Google"
        case .duckduckgo: return "DuckDuckGo"
        case .bing: return "Bing"
        case .ecosia: return "Ecosia"
        case .startpage: return "Startpage"
        case .kagi: return "Kagi"
        case .brave: return "Brave Search"
        case .qwant: return "Qwant"
        case .custom: return String(localized: "Custom")
        }
    }

    func template(custom: String) -> String {
        switch self {
        case .google: return "https://www.google.com/search?q=%s"
        case .duckduckgo: return "https://duckduckgo.com/?q=%s"
        case .bing: return "https://www.bing.com/search?q=%s"
        case .ecosia: return "https://www.ecosia.org/search?q=%s"
        case .startpage: return "https://www.startpage.com/sp/search?query=%s"
        case .kagi: return "https://kagi.com/search?q=%s"
        case .brave: return "https://search.brave.com/search?q=%s"
        case .qwant: return "https://www.qwant.com/?q=%s"
        case .custom:
            let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
            return Engine.accepts(trimmed) ? trimmed : Engine.standard.template(custom: "")
        }
    }

    func name(custom: String) -> String {
        guard self == .custom else { return title }
        return Engine.bareHost(of: custom) ?? Engine.standard.title
    }

    /// Where the engine's suggestions come from, for the words so far. None
    /// for a search address of one's own.
    func suggestions(for words: String) -> URL? {
        guard let q = words.addingPercentEncoding(withAllowedCharacters: Engine.unreserved) else { return nil }
        let base: String
        switch self {
        case .google: base = "https://suggestqueries.google.com/complete/search?client=firefox&q="
        case .duckduckgo: base = "https://duckduckgo.com/ac/?type=list&q="
        case .bing: base = "https://api.bing.com/osjson.aspx?query="
        case .ecosia: base = "https://ac.ecosia.org/autocomplete?type=list&q="
        case .startpage: base = "https://www.startpage.com/osuggestions?q="
        case .kagi: base = "https://kagi.com/api/autosuggest?q="
        case .brave: base = "https://search.brave.com/api/suggest?q="
        case .qwant: base = "https://api.qwant.com/v3/suggest?q="
        case .custom: return nil
        }
        return URL(string: base + q)
    }

    /// The OpenSearch answer, ["words", ["one", "two"]], or Qwant's own.
    static func parseSuggestions(_ data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        if let list = json as? [Any], list.count > 1, let words = list[1] as? [String] {
            return words
        }
        if let object = json as? [String: Any],
           let inner = object["data"] as? [String: Any],
           let items = inner["items"] as? [[String: Any]] {
            return items.compactMap { $0["value"] as? String }
        }
        return []
    }

    static func accepts(_ template: String) -> Bool {
        host(of: template) != nil
    }

    /// The words searched for, when an address is a results page of any of
    /// the engines (or one's own): what the bar shows in place of the
    /// engine's logo and name, as Safari does. Nil for any other page.
    static func words(in url: URL, custom: String) -> String? {
        guard let page = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = page.host?.lowercased()
        else { return nil }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = page.path.isEmpty ? "/" : page.path
        for engine in Engine.allCases {
            let template = engine.template(custom: custom)
            guard let form = URLComponents(string: template.replacingOccurrences(of: "%s", with: mark)),
                  let formHost = form.host?.lowercased(),
                  let name = form.queryItems?.first(where: { $0.value == mark })?.name
            else { continue }
            let formBare = formHost.hasPrefix("www.") ? String(formHost.dropFirst(4)) : formHost
            // Google answers from its country sites too: google.es, google.co.uk.
            let same = bare == formBare || (engine == .google && bare.hasPrefix("google."))
            guard same, path == (form.path.isEmpty ? "/" : form.path) else { continue }
            // "+" is a space in a query; a typed plus arrives as %2B.
            guard let raw = page.percentEncodedQueryItems?.first(where: { $0.name == name })?.value,
                  let words = raw.replacingOccurrences(of: "+", with: "%20").removingPercentEncoding?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !words.isEmpty
            else { continue }
            return words
        }
        return nil
    }

    /// A template's host, with any leading "www." dropped — what a person
    /// would call the site if you asked them.
    static func bareHost(of template: String) -> String? {
        guard let host = host(of: template) else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func url(for text: String, template: String) -> URL? {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty,
              let escaped = words.addingPercentEncoding(withAllowedCharacters: unreserved),
              let base = URL(string: template.replacingOccurrences(of: "%s", with: mark))?.absoluteString
        else { return nil }
        return URL(string: base.replacingOccurrences(of: mark, with: escaped), encodingInvalidCharacters: false)
    }

    private static let mark = "SEARCHWORDSGOHERE"

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func host(of template: String) -> String? {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("%s"),
              let parts = URLComponents(string: trimmed.replacingOccurrences(of: "%s", with: "a")),
              let other = URLComponents(string: trimmed.replacingOccurrences(of: "%s", with: "b")),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host, !host.isEmpty, host == other.host
        else { return nil }
        return host.lowercased()
    }
}
