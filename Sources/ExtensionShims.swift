import CryptoKit
import NaturalLanguage
import SwiftUI
import UserNotifications
import WebKit

// Chrome's APIs that WebKit doesn't have, filled in by the browser itself.
//
// Ported from Search for the Mac (ExtensionShims.swift, MIT, Office Commun):
// when an extension is installed a script is put at the front of its
// background and of every page it ships. There `chrome.sidePanel` and the
// rest are defined, and every call becomes a native message to this app. To
// the extension it looks like Chrome. Only added to, after the store's
// signature has been checked.
//
// What differs here: iOS starts no service worker for this app, so the
// background is a page (Background, in Extensions.swift); there is one
// window; a side panel is a sheet (ExtensionPanel); and chrome.debugger,
// which Claude's extension works pages with, is answered (ExtensionDebugger).

enum ExtensionShims {
    static let application = "search"
    nonisolated static let file = "search-shim.js"
    /// What content scripts carry: the script up to where a content script's
    /// run of it ends.
    nonisolated static let contentFile = "search-shim-content.js"
    nonisolated static let contentEnd = "/* Search: a content script's shim ends here */"
    nonisolated static let marker = "/* Search: Chrome APIs WebKit lacks, filled in (ExtensionShims.swift) */"
    nonisolated static let ender = "/* Search: end of shim */"

    nonisolated static let script: String = {
        guard let url = Bundle.main.url(forResource: "ExtensionShim", withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }()

    /// Written beside a prepared extension: which scripts it carries.
    nonisolated static let stamp = ".search-shim"
    nonisolated private static let preparation = "ios-8"
    nonisolated static let version: String = {
        SHA256.hash(data: Data((script + Background.script + preparation).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }()

    struct Unsupported: LocalizedError {
        let what: String
        var errorDescription: String? { what }
    }

    // MARK: - at install

    /// Chrome's least for a Manifest V3 extension's own pages, whatever its
    /// manifest asks: scripts only from the package, WebAssembly allowed.
    nonisolated static let minimumPagesPolicy = "script-src 'self' 'wasm-unsafe-eval'; object-src 'self'"

    /// A Manifest V3 manifest with its pages' policy held to that minimum,
    /// as Chrome holds it. WebKit uses the manifest's policy as it is, and
    /// one that names no script-src restricts no script. A policy already
    /// within the minimum is left alone; any other gets the minimum beside
    /// it, as a second policy a page has to satisfy as well, as Chrome adds
    /// its own.
    nonisolated static func holdingPagesPolicy(_ manifest: [String: Any]) -> [String: Any] {
        guard (manifest["manifest_version"] as? Int) == 3 else { return manifest }
        let held = { (policy: String) -> String in
            if policy.hasSuffix(", " + minimumPagesPolicy) || withinMinimum(policy) { return policy }
            let given = policy.trimmingCharacters(in: .whitespacesAndNewlines)
            return given.isEmpty ? minimumPagesPolicy : given + ", " + minimumPagesPolicy
        }
        var manifest = manifest
        if let policy = manifest["content_security_policy"] as? String {
            manifest["content_security_policy"] = held(policy)
        } else if var policies = manifest["content_security_policy"] as? [String: Any],
                  let policy = policies["extension_pages"] as? String {
            policies["extension_pages"] = held(policy)
            manifest["content_security_policy"] = policies
        }
        return manifest
    }

    /// One policy, with a script-src, whose script directives allow only
    /// what Chrome's minimum does, or a local server, as Chrome lets a
    /// package in development.
    nonisolated static func withinMinimum(_ policy: String) -> Bool {
        guard !policy.contains(",") else { return false }
        let scripts: Set = ["script-src", "script-src-elem", "script-src-attr", "worker-src", "object-src"]
        let allowed: Set = ["'self'", "'wasm-unsafe-eval'", "'none'", "'inline-speculation-rules'"]
        let local = #/https?://(localhost|127\.0\.0\.1)(:(\d+|\*))?/?/#
        let directives = policy.split(separator: ";").map { $0.split(whereSeparator: \.isWhitespace).map { $0.lowercased() } }
        guard directives.contains(where: { $0.first == "script-src" }) else { return false }
        return directives.allSatisfy { words in
            guard let name = words.first, scripts.contains(name) else { return true }
            return words.dropFirst().allSatisfy { allowed.contains($0) || $0.wholeMatch(of: local) != nil }
        }
    }

    /// What a worker brings in as it runs, with a name it works out
    /// (Bitwarden's does). The page it is here can't run a file there and
    /// then, so each that could be meant is put in a function, in a file of
    /// its own listed ahead of the worker, for importScripts to call. Only
    /// for a worker that does this, and a file that isn't a script on its
    /// own (a module) stops nothing but itself.
    nonisolated static let importsFolder = "search-imports"

    nonisolated static func wrapImports(_ manifest: [String: Any], in folder: URL) -> [String] {
        let files = FileManager.default
        let out = folder.appendingPathComponent(importsFolder, isDirectory: true)
        try? files.removeItem(at: out)
        guard let background = manifest["background"] as? [String: Any], background["type"] as? String != "module",
              let scripts = background["scripts"] as? [String], let worker = scripts.last else { return [] }
        let ours: Set = [Background.file, file, contentFile, "search-passkeys.js"]
        let own = scripts.filter { !ours.contains($0) && !$0.hasPrefix(importsFolder + "/") }
        let computed = try! NSRegularExpression(pattern: #"\bimportScripts\s*\(\s*[^"'`\s)]"#)
        guard own.contains(where: { name in
            guard let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) else { return false }
            return computed.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }) else { return [] }
        // Beside the worker or under it, as bundlers put them.
        let base = folder.appendingPathComponent((worker as NSString).deletingLastPathComponent).standardizedFileURL
        let root = folder.standardizedFileURL.path + "/"
        var made: [String] = []
        let walker = files.enumerator(at: base, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        while let found = walker?.nextObject() as? URL, made.count < 80 {
            let url = found.standardizedFileURL
            guard url.pathExtension == "js", url.path.hasPrefix(root),
                  (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap({ $0 }) ?? .max < 2_000_000
            else { continue }
            let name = String(url.path.dropFirst(root.count))
            guard !ours.contains(url.lastPathComponent), !own.contains(name), !name.hasPrefix(importsFolder + "/"),
                  var text = try? String(contentsOf: url, encoding: .utf8),
                  // What a bundler's part looks like: it hands itself over.
                  text.contains("webpackChunk") || text.contains("webpackJsonp") || text.contains(".push([[") || text.hasPrefix("exports.") || text.contains("self.")
            else { continue }
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
            try? files.createDirectory(at: out, withIntermediateDirectories: true)
            let target = "\(importsFolder)/\(made.count).js"
            let key = (try? JSONSerialization.data(withJSONObject: ["/" + name], options: .withoutEscapingSlashes)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            let whole = "\u{FEFF}(globalThis.__searchImports ||= {})[\(key)[0]] = function () {\n\(text)\n};\n"
            guard (try? whole.write(to: folder.appendingPathComponent(target), atomically: true, encoding: .utf8)) != nil else { continue }
            made.append(target)
        }
        return made
    }

    /// Safe to run again: the same scripts need nothing redone.
    nonisolated static func prepare(_ folder: URL) throws {
        let files = FileManager.default
        let stampURL = folder.appendingPathComponent(stamp)
        if (try? String(contentsOf: stampURL, encoding: .utf8)) == version { return }
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        else { throw Crx.Refused.unpack }

        try Background.prepare(folder, manifest: &manifest)
        let whole = shim(for: folder).replacingOccurrences(of: "__SEARCH_WORKER_GENERATION__", with: "0")
        try whole.write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
        // Named by the script for what it registers in a page's own world; the
        // Mac's passkey patch goes there, and there is none here.
        try "/* Search */\n".write(to: folder.appendingPathComponent("search-passkeys.js"), atomically: true, encoding: .utf8)
        try contentShim(whole).write(to: folder.appendingPathComponent(contentFile), atomically: true, encoding: .utf8)

        // Native messaging is how the script reaches the browser; user
        // scripts are carried out through registered content scripts. What
        // is added is written down, so the extension is described by what it
        // asked for.
        var permissions = manifest["permissions"] as? [Any] ?? []
        let asked = Set(permissions.compactMap { $0 as? String })
        var added = (try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(".search-added")))) as? [String] ?? []
        for needed in ["nativeMessaging"] + (asked.contains("userScripts") ? ["scripting"] : []) where !asked.contains(needed) {
            permissions.append(needed)
            added.append(needed)
        }
        manifest["permissions"] = permissions
        if let data = try? JSONSerialization.data(withJSONObject: Array(Set(added)).sorted()) {
            try? data.write(to: folder.appendingPathComponent(".search-added"))
        }

        // The background's first script of its own.
        if var background = manifest["background"] as? [String: Any], var scripts = background["scripts"] as? [String] {
            scripts.removeAll { $0 == file }
            scripts.removeAll { $0.hasPrefix(importsFolder + "/") }
            let at = scripts.first == Background.file ? 1 : 0
            scripts.insert(file, at: at)
            scripts.insert(contentsOf: wrapImports(manifest, in: folder), at: at + 1)
            background["scripts"] = scripts
            manifest["background"] = background
        }

        // Content scripts carry the part that mends Chrome's behaviour there;
        // one that runs in the page's own world has no extension APIs.
        if let entries = manifest["content_scripts"] as? [[String: Any]] {
            manifest["content_scripts"] = entries.map { entry -> [String: Any] in
                var entry = entry
                guard var js = entry["js"] as? [String] else { return entry }
                js.removeAll { $0 == contentFile || $0 == file }
                if (entry["world"] as? String)?.uppercased() != "MAIN", !js.isEmpty { js.insert(contentFile, at: 0) }
                entry["js"] = js
                return entry
            }
        }

        manifest = holdingPagesPolicy(manifest)
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: manifestURL, options: .atomic)
        dropMisreadRules(manifest, in: folder)

        // Every page it ships, and scripts a content script may insert into a
        // website: WebKit reads those in the site's encoding unless the file
        // says otherwise, so a UTF-8 signature is put on them.
        let signature = Data([0xEF, 0xBB, 0xBF])
        let walker = files.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = walker?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            if ["js", "mjs"].contains(url.pathExtension.lowercased()) {
                guard let bytes = try? Data(contentsOf: url),
                      !bytes.starts(with: signature), bytes.contains(where: { $0 >= 0x80 }),
                      String(data: bytes, encoding: .utf8) != nil,
                      !bytes.starts(with: [0x23, 0x21])
                else { continue }
                try? (signature + bytes).write(to: url, options: .atomic)
                continue
            }
            guard ["html", "htm"].contains(url.pathExtension.lowercased()),
                  var html = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            if let chained = chainModules(html, page: url, folder: folder) {
                html = chained
                try? html.write(to: url, atomically: true, encoding: .utf8)
            }
            let first = "<script src=\"/\(Background.file)\"></script>", second = "<script src=\"/\(file)\"></script>"
            guard !html.contains(second) else { continue }
            // One an earlier version put there goes: both go in together.
            html = html.replacingOccurrences(of: first, with: "")
            if let head = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
                html.insert(contentsOf: first + second, at: head.upperBound)
            } else if let type = html.range(of: "<!doctype[^>]*>", options: [.regularExpression, .caseInsensitive]) {
                html.insert(contentsOf: first + second, at: type.upperBound)
            } else {
                html = first + second + html
            }
            try? html.write(to: url, atomically: true, encoding: .utf8)
        }
        try? version.write(to: stampURL, atomically: true, encoding: .utf8)
    }

    // MARK: - request rules WebKit would misread

    /// A redirect or header rule with a pattern (`regexFilter`) beside a
    /// list of sites (`requestDomains`). WebKit drops the list from such a
    /// rule and carries it out on every address the pattern matches. Since
    /// Search grants "declarativeNetRequestWithHostAccess" with
    /// "declarativeNetRequest" (Norma's block page), WebKit carries out
    /// redirects, and uBlock Origin Lite's strict blocking — `^https?://.*`
    /// beside thousands of named sites, to its warning page — took every
    /// page ~30 s after launch, leaving the tab blank (#709). Such a rule
    /// is left out: nothing is rewritten into something the extension
    /// didn't write, and nothing acts beyond what it named. A block or an
    /// allow of that shape is left as WebKit reads it, as before. The shim
    /// leaves out the same rules added while the extension runs (`misread`).
    ///
    /// A rule that hangs on a response's headers (`responseHeaders`,
    /// `excludedResponseHeaders`), whatever it does. WebKit has no such
    /// condition, drops it, and carries out the rest on every request it
    /// matches: uBlock Origin Lite's block of a site's own `.bundle.js`
    /// when the server answers with an anti-adblock header took every
    /// webpack bundle GitLab serves, and its pages stayed empty.
    nonisolated static func misreadByWebKit(_ rule: [String: Any]) -> Bool {
        guard let condition = rule["condition"] as? [String: Any] else { return false }
        if condition["responseHeaders"] != nil || condition["excludedResponseHeaders"] != nil { return true }
        guard condition["regexFilter"] is String, condition["requestDomains"] != nil,
              let type = (rule["action"] as? [String: Any])?["type"] as? String
        else { return false }
        return type == "redirect" || type == "modifyHeaders"
    }

    /// The rulesets a manifest declares, without the rules WebKit would
    /// misread. Only ever takes rules out; a ruleset with none is left as
    /// it is, so preparing again changes nothing.
    nonisolated static func dropMisreadRules(_ manifest: [String: Any], in folder: URL) {
        guard let dnr = manifest["declarative_net_request"] as? [String: Any],
              let resources = dnr["rule_resources"] as? [[String: Any]] else { return }
        for resource in resources {
            // Only a file with the words in it is read as rules: a blocker
            // ships tens of megabytes of them.
            guard let name = resource["path"] as? String, let url = inside(name, of: folder),
                  let data = try? Data(contentsOf: url),
                  data.range(of: Data("ResponseHeaders".utf8)) != nil || data.range(of: Data("responseHeaders".utf8)) != nil
                    || (data.range(of: Data("regexFilter".utf8)) != nil && data.range(of: Data("requestDomains".utf8)) != nil),
                  let rules = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
            else { continue }
            let kept = rules.filter { !(($0 as? [String: Any]).map(misreadByWebKit) ?? false) }
            guard kept.count < rules.count,
                  let written = try? JSONSerialization.data(withJSONObject: kept, options: [.withoutEscapingSlashes])
            else { continue }
            try? written.write(to: url, options: .atomic)
        }
    }

    nonisolated private static let scriptTagExpression = try! NSRegularExpression(pattern: #"<script\b([^>]*)>\s*</script>"#, options: [.caseInsensitive])
    nonisolated private static let moduleTypeExpression = try! NSRegularExpression(pattern: #"\btype\s*=\s*["']?module\b"#, options: [.caseInsensitive])
    nonisolated private static let srcExpression = try! NSRegularExpression(pattern: #"\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#, options: [.caseInsensitive])
    nonisolated private static let asyncExpression = try! NSRegularExpression(pattern: #"(^|\s)async(\s|=|$)"#, options: [.caseInsensitive])

    /// A page's module scripts, two or more of them with one that awaits,
    /// made one module that imports them in their order: nil when there is
    /// nothing to do. Chrome waits for a module still at a top-level await
    /// before running a later tag's module that imports it; WebKit runs the
    /// later one at once, which then reads the first one's exports before
    /// they exist ("Cannot access 'd' before initialization"). Vimium C's
    /// options page lists five, the second awaiting its translations, and
    /// stayed blank. Inside one module's imports WebKit does wait, so the
    /// tags become one, in a file of Search's beside the page (named with
    /// `search-` like the shim). The modules themselves are not touched. Only
    /// plain tags: one marked async, or a src that isn't the package's own
    /// file, leaves the page as it is.
    nonisolated static func chainModules(_ html: String, page: URL, folder: URL) -> String? {
        let whole = NSRange(html.startIndex..., in: html)
        var found: [(range: Range<String.Index>, attributes: String, src: String)] = []
        for match in scriptTagExpression.matches(in: html, range: whole) {
            guard let range = Range(match.range, in: html), let inner = Range(match.range(at: 1), in: html) else { continue }
            let attributes = String(html[inner])
            let span = NSRange(attributes.startIndex..., in: attributes)
            guard moduleTypeExpression.firstMatch(in: attributes, range: span) != nil else { continue }
            guard asyncExpression.firstMatch(in: attributes, range: span) == nil,
                  let named = srcExpression.firstMatch(in: attributes, range: span),
                  let src = (1...3).lazy.compactMap({ Range(named.range(at: $0), in: attributes) }).first.map({ String(attributes[$0]) }),
                  !src.isEmpty, !src.contains(":"), !src.hasPrefix("//"), !src.contains(where: \.isNewline)
            else { return nil }
            found.append((range, attributes, src))
        }
        guard found.count >= 2 else { return nil }
        // The package's own files, and one of them awaiting at all: without
        // an await, every module has run by the time the next tag's does.
        let directory = page.deletingLastPathComponent()
        let root = folder.standardizedFileURL.path + "/"
        var awaits = false
        for entry in found {
            let path = entry.src.split(separator: "?").first.map(String.init) ?? entry.src
            let file = (path.hasPrefix("/") ? folder.appendingPathComponent(String(path.dropFirst())) : directory.appendingPathComponent(path)).standardizedFileURL
            guard file.path.hasPrefix(root), let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            if text.range(of: #"\bawait\b"#, options: .regularExpression) != nil { awaits = true }
        }
        guard awaits else { return nil }
        let name = "search-modules-" + page.deletingPathExtension().lastPathComponent + ".js"
        let imports = found.map { entry -> String in
            let spec = entry.src.hasPrefix("/") || entry.src.hasPrefix("./") || entry.src.hasPrefix("../") ? entry.src : "./" + entry.src
            return "import \"\(spec.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\";"
        }
        do {
            try ("// Search: this page's module scripts, in their order (ExtensionShims.chainModules).\n" + imports.joined(separator: "\n") + "\n")
                .write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        } catch { return nil }
        // The first tag, its other attributes kept (blocking="render"), now
        // naming the one module; the others gone.
        var html = html
        for (index, entry) in found.enumerated().reversed() {
            if index == 0 {
                let span = NSRange(entry.attributes.startIndex..., in: entry.attributes)
                let attributes = srcExpression.stringByReplacingMatches(in: entry.attributes, range: span, withTemplate: NSRegularExpression.escapedTemplate(for: "src=\"\(name)\""))
                html.replaceSubrange(entry.range, with: "<script\(attributes)></script>")
            } else {
                html.removeSubrange(entry.range)
            }
        }
        return html
    }

    /// A worker that is a link to another file of its own package
    /// (StopTheMadness ships `background-143.js` → `background.js`) is made
    /// a copy of that file, so it can carry the shim. A link that leads out
    /// of the package is left as it is, and so left alone.
    nonisolated private static func unlink(_ name: String, in folder: URL) {
        let path = folder.appendingPathComponent(name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).standardizedFileURL
        guard path.path.hasPrefix(folder.standardizedFileURL.path + "/"),
              (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        else { return }
        let root = folder.resolvingSymlinksInPath().path
        let parent = path.deletingLastPathComponent().resolvingSymlinksInPath().path
        let target = path.resolvingSymlinksInPath()
        guard parent == root || parent.hasPrefix(root + "/"),
              target.path.hasPrefix(root + "/"),
              (try? target.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let data = try? Data(contentsOf: target)
        else { return }
        try? FileManager.default.removeItem(at: path)
        try? data.write(to: path)
    }

    /// A path a package names, resolved and kept inside the folder it came
    /// in: `..` in a manifest is not a way out of the package. Nor is a
    /// symbolic link, which a folder install keeps as it is: the worker is
    /// read through it and written back over it as a regular file, so a
    /// link to a file elsewhere would put that file's bytes in the package.
    /// A folder on the way that is a link is caught by where it resolves.
    nonisolated static func inside(_ name: String, of folder: URL) -> URL? {
        let path = folder.appendingPathComponent(name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).standardizedFileURL
        guard path.path.hasPrefix(folder.standardizedFileURL.path + "/"),
              (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              path.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/")
        else { return nil }
        return path
    }

    nonisolated private static let eventExpression = try! NSRegularExpression(pattern: #"\.([a-zA-Z]+)\.(on[A-Z][A-Za-z]+)\b"#)

    /// The shim as this extension gets it: with the events its code mentions
    /// — `chrome.tabs.onUpdated`, `e.runtime.onInstalled` — so its worker
    /// can take their listeners late (see the end of the script).
    nonisolated static func shim(for folder: URL) -> String {
        var found = Set<String>()
        // Whether its own scripts ask for getBackgroundPage: only then does
        // its worker need `window` to be a name it can read (see the script).
        var namesWindow = false
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "js", url.lastPathComponent != file,
                  var text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // Not the shim's own words, in a worker that already carries it.
            if text.hasPrefix(marker), let end = text.range(of: ender) { text = String(text[end.upperBound...]) }
            if url.lastPathComponent != contentFile, text.contains("getBackgroundPage") { namesWindow = true }
            let range = NSRange(text.startIndex..., in: text)
            for match in eventExpression.matches(in: text, range: range) {
                guard let a = Range(match.range(at: 1), in: text), let b = Range(match.range(at: 2), in: text) else { continue }
                found.insert("\(text[a]).\(text[b])")
            }
        }
        let list = (try? JSONSerialization.data(withJSONObject: found.sorted())).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        // And the scripts it ships, so its worker can be told at once that
        // one isn't there (see importScripts in the script).
        var scripts: [String] = []
        let all = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = all?.nextObject() as? URL {
            guard url.pathExtension == "js" else { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count))
            // An empty one is marked: there is nothing to run in it.
            let empty = ((try? String(contentsOf: url, encoding: .utf8)) ?? "x").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            scripts.append((empty ? "-" : "") + path)
        }
        let shipped = (try? JSONSerialization.data(withJSONObject: scripts.sorted())).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return script.replacingOccurrences(of: "__SEARCH_EVENTS__", with: list)
            .replacingOccurrences(of: "__SEARCH_SCRIPTS__", with: shipped)
            .replacingOccurrences(of: "__SEARCH_CHROME__", with: Crx.chromeVersion)
            .replacingOccurrences(of: "__SEARCH_VERBOSE__", with: "false")
            .replacingOccurrences(of: "__SEARCH_NAMES_WINDOW__", with: namesWindow ? "yes" : "no")
    }

    /// The shim as a content script runs it: everything up to the `return`
    /// that ends a content script's run, then the function closed. Nothing
    /// after that point is declared before it (no function declarations to
    /// hoist; the names after it are only ever read after it), so a content
    /// script does exactly what it did with the whole file. Without the
    /// mark, the whole shim, as before.
    ///
    /// A frame often gets it more than once, from each entry that carries
    /// it (uBlock Origin Lite registers two for every frame); every copy
    /// after the first returns at its first check. Asked before the
    /// function rather than inside it, that check spares those copies
    /// compiling the function at all: it is only read, not built.
    nonisolated static func contentShim(_ full: String) -> String {
        guard let end = full.range(of: contentEnd) else { return full }
        return "if (!globalThis.__searchShim) " + String(full[..<end.lowerBound]) + "})();\n"
    }

    // MARK: - script injection and user scripts

    /// A function sent by an extension page inside a website's frame cannot
    /// survive the JSON message to its worker. Write it as a file for WebKit's
    /// scripting API, with its JSON arguments and final result intact.
    static func scriptingFile(_ function: String, arguments: [Any], in folder: URL) throws -> String {
        // A megabyte of source at most: a page gone wrong can't fill the
        // extension's folder with big files (Security).
        guard !function.isEmpty, function.utf8.count <= 1_000_000, JSONSerialization.isValidJSONObject(arguments),
              let data = try? JSONSerialization.data(withJSONObject: arguments),
              let args = String(data: data, encoding: .utf8)
        else { throw Unsupported(what: "Invalid script function or arguments") }
        let source = "(\(function))(...\(args))\n"
        let name = "script-" + SHA256.hash(data: Data(source.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() + ".js"
        let dir = folder.appendingPathComponent("_search", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) { try source.write(to: url, atomically: true, encoding: .utf8) }
        for old in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where old.lastPathComponent.hasPrefix("script-") && old != url {
            let age = (try? old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { -$0.timeIntervalSinceNow } ?? 0
            if age > 60 { try? FileManager.default.removeItem(at: old) }
        }
        return "_search/" + name
    }

    /// A user script as a file WebKit can inject: its code — inline, or read
    /// from the extension's own files — inside a block that leaves at once
    /// on a page its globs rule out and, for Chrome's USER_SCRIPT world,
    /// gives the code a `chrome` whose messages are marked as a user
    /// script's. Named by what is in it, so a changed script is a new file
    /// and never a stale one WebKit has already read.
    static func userScriptFile(_ script: [String: Any], in folder: URL) throws -> String {
        let json = { (value: Any) in
            (try? JSONSerialization.data(withJSONObject: value)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
        var code = ""
        for source in script["js"] as? [[String: Any]] ?? [] {
            if let inline = source["code"] as? String {
                code += inline + "\n;\n"
            } else if let file = source["file"] as? String,
                      // One of the extension's own files, and nothing outside
                      // its folder: a name is resolved before it is read.
                      let path = inside(file, of: folder),
                      let text = try? String(contentsOf: path, encoding: .utf8) {
                code += text + "\n;\n"
            }
        }
        let userWorld = (script["world"] as? String) != "MAIN"
        let prelude = #"""
          const chrome = (() => {
            const runtime = globalThis.chrome.runtime;
            return { runtime: {
              id: runtime.id, getURL: (path) => runtime.getURL(path), get lastError() { return runtime.lastError; },
              sendMessage: (message, ...rest) => runtime.sendMessage({ __searchUserScript: true, message }, ...rest.filter((r) => typeof r === "function" || (r && typeof r === "object"))),
              connect: (info) => runtime.connect({ ...(info || {}), name: "search-us:" + ((info && info.name) || "") }),
            } };
          })();
          const browser = chrome;
        """#
        let text = #"""
        /* Search: a user script (chrome.userScripts) */
        search_user_script: {
          const __searchHref = location.href;
          const __searchGlob = (g) => new RegExp("^" + g.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".") + "$");
          const __searchIn = \#(json(script["includeGlobs"] ?? [])), __searchOut = \#(json(script["excludeGlobs"] ?? []));
          if ((__searchIn.length && !__searchIn.some((g) => __searchGlob(g).test(__searchHref))) || __searchOut.some((g) => __searchGlob(g).test(__searchHref))) break search_user_script;
        \#(userWorld ? prelude : "")
        \#(code)
        }
        """#
        let name = "us-" + SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() + ".js"
        let dir = folder.appendingPathComponent("_search", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) { try text.write(to: url, atomically: true, encoding: .utf8) }
        return "_search/" + name
    }

}
