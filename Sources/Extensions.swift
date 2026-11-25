import SwiftUI
import WebKit
import Combine
import Compression
import CryptoKit
import Security

// Chrome extensions on the iPhone, on WebKit's own extension engine — the
// one Safari uses (iOS 18.4 and later). Held, the knight's seal lists them.
//
// An extension comes straight from the Chrome Web Store: the .crx Chrome
// itself would get, its signature checked against the extension's id (the
// Mac's Crx.swift, unzipped here without `ditto`), unpacked into the app's
// own folder and loaded. It gets the permissions and sites it asks for once
// you say yes, and never private tabs.

// MARK: - the Chrome Web Store

enum Crx {
    enum Refused: LocalizedError {
        case notAnID, download(Int), empty, notCrx, unsignedOrWrong, unpack

        var errorDescription: String? {
            switch self {
            case .notAnID: return String(localized: "That isn't a Chrome Web Store link or extension id.")
            case .download(let code): return String(localized: "The Chrome Web Store answered \(code).")
            case .empty: return String(localized: "The Chrome Web Store has nothing for that id.")
            case .notCrx: return String(localized: "What came back isn't a Chrome extension.")
            case .unsignedOrWrong: return String(localized: "The extension's signature doesn't hold up.")
            case .unpack: return String(localized: "The extension couldn't be unpacked.")
            }
        }
    }

    /// The Chrome the store is told it is talking to (the Mac's, kept in step).
    static let chromeVersion = "156.0.0.0"

    private static let idExpression = try! NSRegularExpression(pattern: "(?<![a-z])([a-p]{32})(?![a-z])")

    /// Thirty-two letters from a to p, wherever they are: a bare id or a
    /// store link, old or new.
    static func id(in text: String) -> String? {
        let lower = text.lowercased()
        let range = NSRange(lower.startIndex..., in: lower)
        guard let match = idExpression.firstMatch(in: lower, range: range),
              let found = Range(match.range(at: 1), in: lower)
        else { return nil }
        return String(lower[found])
    }

    private static let storeDetailExpression = try! NSRegularExpression(pattern: #"^/detail/(?:[^/]+/)?([a-p]{32})(?:/.*)?$"#)
    private static let webstoreDetailExpression = try! NSRegularExpression(pattern: #"^/webstore/detail/(?:[^/]+/)?([a-p]{32})(?:/.*)?$"#)

    /// The extension a store page is about: the id in its /detail/ path and
    /// nowhere else. Only on the store itself, over https.
    static func storeID(of url: URL) -> String? {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil else { return nil }
        let expression: NSRegularExpression
        switch url.host()?.lowercased() ?? "" {
        case "chromewebstore.google.com": expression = storeDetailExpression
        case "chrome.google.com": expression = webstoreDetailExpression
        default: return nil
        }
        let path = url.path
        guard let match = expression.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
              let found = Range(match.range(at: 1), in: path)
        else { return nil }
        return String(path[found])
    }

    static func downloadURL(for id: String) -> URL {
        var parts = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        parts.queryItems = [
            URLQueryItem(name: "response", value: "redirect"),
            URLQueryItem(name: "prodversion", value: chromeVersion),
            URLQueryItem(name: "acceptformat", value: "crx3"),
            URLQueryItem(name: "x", value: "id=\(id)&installsource=ondemand&uc"),
        ]
        return parts.url!
    }

    static func fetch(_ id: String) async throws -> Data {
        var request = URLRequest(url: downloadURL(for: id))
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Refused.download(http.statusCode)
        }
        guard !data.isEmpty else { throw Refused.empty }
        return data
    }

    /// The zip inside a CRX3, once its signature has been checked against
    /// `id`: the header must carry the key the id is made from (the first
    /// sixteen bytes of its SHA-256, as letters a to p) and a signature by
    /// that key over the zip.
    static func verifiedZip(_ crx: Data, id: String) throws -> Data {
        let bytes = [UInt8](crx)
        guard bytes.count > 12, Array(bytes[0..<4]) == Array("Cr24".utf8), le32(bytes, 4) == 3 else { throw Refused.notCrx }
        let headerSize = Int(le32(bytes, 8))
        guard 12 + headerSize <= bytes.count else { throw Refused.notCrx }
        let header = Array(bytes[12..<(12 + headerSize)])
        let zip = Data(bytes[(12 + headerSize)...])

        let fields = protobuf(header)
        guard let signedHeader = fields.first(where: { $0.0 == 10000 })?.1,
              let crxID = protobuf(signedHeader).first(where: { $0.0 == 1 })?.1,
              letters(crxID) == id
        else { throw Refused.unsignedOrWrong }

        var message = Data("CRX3 SignedData".utf8)
        message.append(0)
        var length = UInt32(signedHeader.count).littleEndian
        message.append(Data(bytes: &length, count: 4))
        message.append(Data(signedHeader))
        message.append(zip)

        let owns = fields.filter { $0.0 == 2 }.map { protobuf($0.1) }.contains { proof in
            guard let key = proof.first(where: { $0.0 == 1 })?.1,
                  let signature = proof.first(where: { $0.0 == 2 })?.1,
                  letters(Array(SHA256.hash(data: Data(key)).prefix(16))) == id,
                  let publicKey = rsaKey(spki: Data(key))
            else { return false }
            return SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, Data(signature) as CFData, nil)
        }
        guard owns else { throw Refused.unsignedOrWrong }
        return zip
    }

    private static func le32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
    }

    static func letters(_ bytes: [UInt8]) -> String {
        String(bytes.flatMap { [$0 >> 4, $0 & 0x0f] }.map { Character(UnicodeScalar(UInt8(97) + $0)) })
    }

    /// Length-delimited protobuf fields only, which is all a CRX header holds.
    private static func protobuf(_ b: [UInt8]) -> [(Int, [UInt8])] {
        var out: [(Int, [UInt8])] = []
        var i = 0
        func varint() -> Int? {
            var value = 0, shift = 0
            while i < b.count {
                let byte = Int(b[i]); i += 1
                value |= (byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
                if shift > 56 { return nil }
            }
            return nil
        }
        while i < b.count {
            guard let key = varint() else { break }
            switch key & 7 {
            case 2:
                guard let length = varint(), length >= 0, i + length <= b.count else { return out }
                out.append((key >> 3, Array(b[i..<(i + length)])))
                i += length
            case 0: _ = varint()
            case 1: i += 8
            case 5: i += 4
            default: return out
            }
        }
        return out
    }

    /// Chrome writes the key as SubjectPublicKeyInfo; iOS takes the RSA key
    /// inside it (PKCS#1), so the wrapper is read off.
    private static func rsaKey(spki: Data) -> SecKey? {
        let b = [UInt8](spki)
        var i = 0
        func length() -> Int? {
            guard i < b.count else { return nil }
            var l = Int(b[i]); i += 1
            if l & 0x80 != 0 {
                let n = l & 0x7f
                guard n >= 1, n <= 4, i + n <= b.count else { return nil }
                l = 0
                for _ in 0..<n { l = l << 8 | Int(b[i]); i += 1 }
            }
            return l
        }
        guard i < b.count, b[i] == 0x30 else { return nil }; i += 1
        guard length() != nil else { return nil }
        guard i < b.count, b[i] == 0x30 else { return nil }; i += 1
        guard let algorithm = length() else { return nil }
        i += algorithm
        guard i < b.count, b[i] == 0x03 else { return nil }; i += 1
        guard let bits = length(), bits > 1, i + bits <= b.count else { return nil }
        let key = Data(b[(i + 1)..<(i + bits)])
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        return SecKeyCreateWithData(key as CFData, attributes as CFDictionary, nil)
    }
}

// MARK: - unzip

/// Just enough of zip for an extension: stored and deflated entries, no
/// links, nothing that climbs out of the folder.
enum Zip {
    static func extract(_ data: Data, into out: URL) throws {
        let b = [UInt8](data)
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 }
        guard b.count >= 22 else { throw Crx.Refused.unpack }

        // The end of the central directory: its signature, searched from the end.
        var end = -1
        var i = b.count - 22
        let floor = max(0, b.count - 22 - 65535)
        while i >= floor {
            if b[i] == 0x50, b[i + 1] == 0x4b, b[i + 2] == 5, b[i + 3] == 6 { end = i; break }
            i -= 1
        }
        guard end >= 0 else { throw Crx.Refused.unpack }
        let count = u16(end + 10)
        var at = u32(end + 16)

        let files = FileManager.default
        try files.createDirectory(at: out, withIntermediateDirectories: true)
        let root = out.standardizedFileURL.path

        for _ in 0..<count {
            guard at + 46 <= b.count, u32(at) == 0x02014b50 else { throw Crx.Refused.unpack }
            let method = u16(at + 10)
            let compressed = u32(at + 20), size = u32(at + 24)
            let nameLength = u16(at + 28), extraLength = u16(at + 30), commentLength = u16(at + 32)
            let attributes = u32(at + 38)
            let local = u32(at + 42)
            guard at + 46 + nameLength <= b.count else { throw Crx.Refused.unpack }
            let name = String(decoding: b[(at + 46)..<(at + 46 + nameLength)], as: UTF8.self)
            at += 46 + nameLength + extraLength + commentLength

            if (attributes >> 16) & 0o170000 == 0o120000 { throw Crx.Refused.unpack }
            guard !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else { throw Crx.Refused.unpack }
            let target = out.appendingPathComponent(name).standardizedFileURL
            guard target.path.hasPrefix(root + "/") else { throw Crx.Refused.unpack }
            if name.hasSuffix("/") {
                try files.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            guard local + 30 <= b.count, u32(local) == 0x04034b50 else { throw Crx.Refused.unpack }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + compressed <= b.count else { throw Crx.Refused.unpack }
            let raw = Data(b[start..<(start + compressed)])
            let content: Data
            switch method {
            case 0: content = raw
            case 8: content = try inflate(raw, size: size)
            default: throw Crx.Refused.unpack
            }
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: target)
        }
    }

    /// Raw DEFLATE, which is what Compression calls ZLIB.
    private static func inflate(_ raw: Data, size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        guard !raw.isEmpty else { throw Crx.Refused.unpack }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { dst in
            raw.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, size,
                    src.bindMemory(to: UInt8.self).baseAddress!, raw.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == size else { throw Crx.Refused.unpack }
        return out
    }
}

// MARK: - the background, as iOS will run it

/// iOS starts no service worker for an app that isn't on Apple's list of
/// browsers, and a Chrome extension's background almost always is one: it
/// was loaded and never ran a line, so its popup had nobody to answer it.
/// The same script runs as a background page, which iOS does start, so that
/// is what the manifest is made to say, after the store's signature has been
/// checked. A small script goes first, with what a worker has and a page
/// doesn't, and the Chrome APIs whose absence would stop a script that
/// touches them as it loads.
enum Background {
    static let file = "search-background.js"

    /// An extension's files, made ready for iOS: this and ExtensionShims.
    static func prepare(_ folder: URL) throws { try ExtensionShims.prepare(folder) }

    /// The background made a page, and the script that goes first in it.
    static func prepare(_ folder: URL, manifest: inout [String: Any]) throws {
        var ran = (manifest["search_hoisted"] as? [String]) ?? []
        if var background = manifest["background"] as? [String: Any] {
            if let worker = background["service_worker"] as? String {
                // Its scripts for another browser are the worker's equal;
                // the worker is the one written for Chrome.
                let module = (background["type"] as? String) == "module"
                let path = trimmed(worker)
                guard inside(path, of: folder) != nil else { throw Crx.Refused.unpack }
                if !module { ran = imports(of: path, in: folder) }
                background = ["scripts": [file] + ran + [path], "persistent": false]
                if module { background["type"] = "module" }
            } else if var scripts = background["scripts"] as? [String] {
                if scripts.first != file { scripts.insert(file, at: 0) }
                background["scripts"] = scripts
                // iOS keeps no background page awake for good.
                background["persistent"] = false
            } else if background["page"] != nil {
                background["persistent"] = false
            }
            manifest["background"] = background
        }
        manifest["search_hoisted"] = ran
        let list = (try? JSONSerialization.data(withJSONObject: ran.map { "/" + $0 })).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try script.replacingOccurrences(of: "__HOISTED__", with: list)
            .write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    private static func trimmed(_ path: String) -> String {
        var path = path
        while path.hasPrefix("/") || path.hasPrefix("./") { path.removeFirst(path.hasPrefix("/") ? 1 : 2) }
        return path
    }

    /// A path a package names, kept inside the folder it came in.
    private static func inside(_ path: String, of folder: URL) -> URL? {
        let url = folder.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(folder.standardizedFileURL.path + "/"),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    /// What a worker brings in with importScripts, which a page doesn't have:
    /// the files it names outright, theirs first, to be listed ahead of it.
    /// importScripts reads its addresses from the worker's own, always.
    private static func imports(of worker: String, in folder: URL) -> [String] {
        let base = (worker as NSString).deletingLastPathComponent
        let call = try! NSRegularExpression(pattern: #"\bimportScripts\s*\(([^)]*)\)"#)
        let literal = try! NSRegularExpression(pattern: #"(["'`])([^"'`$]+)\1"#)
        var order: [String] = []
        var seen: Set<String> = [worker]

        func visit(_ path: String) {
            guard let url = inside(path, of: folder), let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            for found in call.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(found.range(at: 1), in: text) else { continue }
                let arguments = String(text[range])
                for name in literal.matches(in: arguments, range: NSRange(arguments.startIndex..., in: arguments)) {
                    guard let part = Range(name.range(at: 2), in: arguments) else { continue }
                    let written = String(arguments[part])
                    guard !written.contains("://") else { continue }
                    let whole = written.hasPrefix("/") || base.isEmpty ? written : base + "/" + written
                    let next = trimmed((trimmed(whole) as NSString).standardizingPath)
                    guard inside(next, of: folder) != nil, seen.insert(next).inserted else { continue }
                    visit(next)
                    order.append(next)
                }
            }
        }
        visit(worker)
        return order
    }

    /// What a service worker has and a page doesn't, and the two APIs iOS
    /// lacks that the Mac has or never answers: menus, which nothing shows
    /// here, and chrome.debugger (ExtensionDebugger). It goes before
    /// ExtensionShim.js, which fills in the rest.
    static let script = #"""
    /* Search: what a service worker has and a page doesn't, and Chrome APIs iOS lacks */
    (() => {
      const g = globalThis;
      if (g.__searchBackground) return;
      Object.defineProperty(g, "__searchBackground", { value: true });
      const api = g.chrome || g.browser;
      if (!api || !api.runtime) return;
      const runtime = api.runtime;
      const here = /_generated_background_page/.test(location.pathname);
      let manifest = {};
      try { manifest = runtime.getManifest(); } catch (e) {}

      // There is no service worker to find from a page: one that stands for
      // the background, which the shim after this has talk to it.
      if (typeof navigator !== "undefined" && !navigator.serviceWorker && /extension:$/.test(location.protocol)) {
        const registration = {
          scope: location.origin + "/", active: null, installing: null, waiting: null, update: async () => {},
          unregister: async () => false, addEventListener() {}, removeEventListener() {}, showNotification: async () => {}, getNotifications: async () => [],
        };
        class Container extends EventTarget {
          constructor() { super(); this.onmessage = null; this.oncontrollerchange = null; this.addEventListener("message", (e) => { if (typeof this.onmessage === "function") this.onmessage(e); }); }
          get controller() { return null; }
          get ready() { return Promise.resolve(registration); }
          register() { return Promise.resolve(registration); }
          getRegistration() { return Promise.resolve(registration); }
          getRegistrations() { return Promise.resolve([registration]); }
          startMessages() {}
        }
        const container = new Container();
        try { Object.defineProperty(navigator, "serviceWorker", { configurable: true, get: () => container }); } catch (e) {}
      }

      if (here) {
        const ran = new Set(__HOISTED__);
        const scripts = (manifest.background && manifest.background.scripts) || [];
        const base = new URL("/" + String(scripts[scripts.length - 1] || "").replace(/^\//, ""), location.origin);
        if (typeof g.importScripts !== "function") g.importScripts = (...names) => {
          for (const name of names) {
            const url = new URL(name, base);
            if (ran.has(url.pathname)) continue;
            ran.add(url.pathname);
            // There and then, as a worker runs it, when it was put in a
            // function ahead of time (ExtensionShims.wrapImports).
            const part = g.__searchImports && g.__searchImports[url.pathname];
            if (part) { part.call(g); continue; }
            const s = document.createElement("script");
            s.src = url.href; s.async = false;
            (document.head || document.documentElement).append(s);
          }
        };
        const set = (name, value) => { if (g[name] === undefined) { try { g[name] = value; } catch (e) {} } };
        set("skipWaiting", async () => {});
        set("clients", {
          claim: async () => {}, matchAll: async () => [], get: async () => undefined,
          openWindow: async (url) => { api.tabs.create({ url: new URL(url, location.origin).href }); return null; },
        });
        set("registration", {
          scope: location.origin + "/", active: { state: "activated", scriptURL: base.href }, installing: null, waiting: null,
          showNotification: async (title, o) => { try { await api.notifications.create("", { type: "basic", title, message: (o && o.body) || "" }); } catch (e) {} },
          getNotifications: async () => [], update: async () => {},
          unregister: async () => false, addEventListener() {}, removeEventListener() {},
        });
        // A worker hears these as it starts; a page never would.
        addEventListener("load", () => {
          for (const type of ["install", "activate"]) {
            const e = new Event(type);
            e.waitUntil = (p) => { Promise.resolve(p).catch(() => {}); };
            e.addRoutes = async () => {};
            g.dispatchEvent(e);
          }
        });
      }

      const event = () => { const l = new Set(); return { addListener: (f) => { l.add(f); }, removeListener: (f) => { l.delete(f); }, hasListener: (f) => l.has(f), hasListeners: () => l.size > 0, fire: (...a) => l.forEach((f) => { try { f(...a); } catch (e) { console.error(e); } }) }; };
      // Answers as Chrome's do: a promise, or the callback given last.
      const answer = (value) => (...args) => {
        const back = args[args.length - 1];
        if (typeof back === "function") { setTimeout(() => back(value)); return undefined; }
        return Promise.resolve(value);
      };
      const put = (name, value) => {
        for (const root of new Set([g.chrome, g.browser])) {
          if (!root) continue;
          try { if (root[name] === undefined) Object.defineProperty(root, name, { configurable: true, writable: true, enumerable: true, value }); } catch (e) {}
        }
      };
      const asked = new Set([...(manifest.permissions || []), ...(manifest.optional_permissions || [])]);

      // WebKit refuses an icon given both as pictures and as paths.
      if (api.action && typeof api.action.setIcon === "function") {
        const setIcon = api.action.setIcon.bind(api.action);
        try {
          Object.defineProperty(api.action, "setIcon", { configurable: true, writable: true, value: (details, ...rest) => {
            if (details && details.imageData && details.path) { details = { ...details }; delete details.path; }
            return setIcon(details, ...rest);
          } });
        } catch (e) {}
      }

      let made = 0;
      const menus = {
        create(item, back) { if (typeof back === "function") setTimeout(back); return (item && item.id) || ++made; },
        update: answer(undefined), remove: answer(undefined), removeAll: answer(undefined),
        refresh: answer(undefined), onClicked: event(), onShown: event(), onHidden: event(),
        ACTION_MENU_TOP_LEVEL_LIMIT: 6, ContextType: {}, ItemType: {},
      };
      if (asked.has("contextMenus") || asked.has("menus")) { put("contextMenus", menus); put("menus", menus); }

      // chrome.debugger, over the tab's own web view.
      if (asked.has("debugger") && api.tabs && typeof runtime.sendNativeMessage === "function") {
        const send = runtime.sendNativeMessage.bind(runtime);
        const ask = async (name, target, ...rest) => {
          let place = null;
          if (target && typeof target.tabId === "number") {
            let tab;
            try { tab = await api.tabs.get(target.tabId); } catch (e) {}
            if (!tab) throw new Error("No tab with given id " + target.tabId + ".");
            place = { i: tab.index, u: tab.url || tab.pendingUrl || "", n: target.tabId };
          }
          const reply = await send("search", { api: "debugger." + name, args: [place, ...JSON.parse(JSON.stringify(rest))] });
          if (reply && reply.error) throw new Error(reply.error);
          return reply ? reply.value : undefined;
        };
        // As Chrome's: lastError for a callback, a rejection without one.
        const chromes = (make) => (...args) => {
          const back = typeof args[args.length - 1] === "function" ? args.pop() : null;
          const p = make(...args);
          if (!back) return p;
          p.then((v) => back(v), (e) => {
            // WebKit's own lastError can't be put there: it is made to set it.
            const words = String((e && e.message) || e);
            try { send("search.error", { message: words }, () => back()); }
            catch (x) { back(); }
          });
        };
        const onEvent = event(), onDetach = event();
        put("debugger", {
          attach: chromes(async (target, version) => { await ask("attach", target); }),
          detach: chromes(async (target) => { await ask("detach", target); }),
          sendCommand: chromes(async (target, method, params) => {
            if (target && target.targetId !== undefined && target.tabId === undefined) return {};
            const result = await ask("send", target, method, params || {});
            for (const e of (result && result.__events) || []) onEvent.fire({ tabId: target.tabId }, e.method, e.params || {});
            if (result) delete result.__events;
            return result;
          }),
          getTargets: chromes(async () => {
            const held = new Set(await ask("attached", null) || []);
            return (await api.tabs.query({})).map((t) => ({ id: "tab-" + t.id, tabId: t.id, type: "page", title: t.title || "", url: t.url || "", attached: held.has(t.id) }));
          }),
          onEvent, onDetach,
          DetachReason: { TARGET_CLOSED: "target_closed", CANCELED_BY_USER: "canceled_by_user" },
          TargetInfoType: { PAGE: "page", BACKGROUND_PAGE: "background_page", WORKER: "worker", OTHER: "other" },
        });
      }
    })();
    """#
}

// MARK: - the extensions

@available(iOS 18.4, *)
@MainActor
final class Extensions: NSObject, ObservableObject {
    static let shared = Extensions()

    let controller: WKWebExtensionController = {
        // Chrome's own address for an extension's pages (chrome-extension://
        // <id>/): extensions check who is talking to them by it.
        WKWebExtension.MatchPattern.registerCustomURLScheme(Extensions.scheme)
        let configuration = WKWebExtensionController.Configuration.default()
        let views = configuration.webViewConfiguration ?? WKWebViewConfiguration()
        views.applicationNameForUserAgent = Web.userAgentTail
        views.allowsInlineMediaPlayback = true
        configuration.webViewConfiguration = views
        return WKWebExtensionController(configuration: configuration)
    }()
    weak var browser: Browser? {
        didSet { follow() }
    }

    struct Item: Codable, Identifiable, Equatable {
        let id: String
        var name: String
        var version: String
        var on: Bool
    }
    @Published private(set) var items: [Item] = []
    @Published private(set) var adding = false
    /// The extension on its way, for a store page's button.
    @Published private(set) var addingID: String?
    @Published var problem: String?

    /// Downloaded, checked and unpacked, waiting for a yes.
    struct Pending: Identifiable {
        let id: String
        let name: String
        let version: String
        let wants: String
        let staged: URL
    }
    @Published var pending: Pending?

    private(set) var contexts: [String: WKWebExtensionContext] = [:]
    private var adapters: [Tab.ID: ExtensionTab] = [:]
    private(set) lazy var window = ExtensionWindow(owner: self)
    private var watching: Set<AnyCancellable> = []
    private var known: [Tab.ID] = []
    private var tabWatching: [Tab.ID: AnyCancellable] = [:]
    private weak var popup: UIViewController?
    private var popupOwner: String?
    var popupID: String? { popup?.presentingViewController != nil ? popupOwner : nil }
    /// What the script asks of a load (ExtensionShims.run).
    var sessionGiven: Set<String> = []
    var sessionSpilled: Set<String> = []
    private(set) var loadedAt: [String: Date] = [:]
    private var installing: Set<String> = []
    private var loadedBefore: Set<String> = []
    private(set) var notes: [String: [String]] = [:]
    /// Ports held open, dropped as they close.
    fileprivate var kept: [WKWebExtension.MessagePort] = [] {
        didSet { if kept.contains(where: \.isDisconnected) { kept.removeAll(where: \.isDisconnected) } }
    }

    static var root: URL { Store.folder.appendingPathComponent("Extensions", isDirectory: true) }
    static func folder(for id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    private static var list: URL { root.appendingPathComponent("installed.json") }

    private override init() {
        super.init()
        controller.delegate = self
        items = (try? JSONDecoder().decode([Item].self, from: Data(contentsOf: Self.list))) ?? []
        Task {
            for item in items where item.on { await start(item.id) }
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        try? JSONEncoder().encode(items).write(to: Self.list)
    }

    // MARK: loading

    private func start(_ id: String) async {
        guard contexts[id] == nil else { return }
        do {
            // Again at every start: an extension added before, or with an
            // older copy of the script, is brought up to date.
            let folder = Self.folder(for: id)
            try await Task.detached { try Background.prepare(folder) }.value
            let found = try await WKWebExtension(resourceBaseURL: folder)
            guard contexts[id] == nil else { return }
            let context = WKWebExtensionContext(for: found)
            context.uniqueIdentifier = id
            // One address for good. WebKit's own is new at every launch, and
            // what an extension keeps in its pages' storage went with it.
            if let stable = URL(string: "\(Self.scheme)://\(id)/") { context.baseURL = stable }
            // What it asked for, said yes to when it was added.
            for permission in found.requestedPermissions {
                context.setPermissionStatus(.grantedExplicitly, for: permission)
            }
            // The line to the app the script asks on.
            context.setPermissionStatus(.grantedExplicitly, for: .nativeMessaging)
            // WebKit carries out redirects and header rules only with this
            // one; it still holds them to the sites granted.
            if found.requestedPermissions.contains(.declarativeNetRequest) {
                context.setPermissionStatus(.grantedExplicitly, for: .declarativeNetRequestWithHostAccess)
            }
            for pattern in found.allRequestedMatchPatterns where !Self.reachesExtensions(pattern) {
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }
            if ExtensionShims.allowed(id, context: context).contains("identity"),
               let own = try? WKWebExtension.MatchPattern(string: "https://\(id).chromiumapp.org/*") {
                context.setPermissionStatus(.grantedExplicitly, for: own)
            }
            Self.fence(context)
            context.hasAccessToPrivateData = false
            context.isInspectable = true
            if loadedAt[id] != nil { loadedBefore.insert(id) }
            loadedAt[id] = Date()
            sessionGiven.remove(id)
            sessionSpilled.remove(id)
            try controller.load(context)
            contexts[id] = context
            // Some extensions listen to tabs.onUpdated instead of declaring
            // content_scripts. Give newly loaded extensions the current state.
            for tab in visibleTabs {
                context.didChangeTabProperties([.URL, .loading, .title], for: adapter(for: tab))
            }
        } catch {
            problem = String(localized: "\(name(of: id)) couldn't start: \(error.localizedDescription)")
        }
    }

    /// How an extension's own pages are addressed, its id the host.
    nonisolated static let scheme = "chrome-extension"

    /// Extension pages, as a pattern names them. No extension is ever given
    /// another's: with the scheme registered, WebKit counts them in
    /// <all_urls>, which Chrome doesn't.
    nonisolated static func reachesExtensions(_ pattern: WKWebExtension.MatchPattern) -> Bool {
        [scheme, "webkit-extension", "file"].contains(pattern.scheme?.lowercased() ?? "")
    }

    /// Refused outright, and what <all_urls> means for websites kept: WebKit
    /// takes back a grant that covers what is refused.
    static func fence(_ context: WKWebExtensionContext) {
        let every = context.grantedPermissionMatchPatterns.keys.contains { $0.matchesAllURLs }
        for string in ["\(scheme)://*/*", "webkit-extension://*/*", "file:///*"] {
            if let pattern = try? WKWebExtension.MatchPattern(string: string) {
                context.setPermissionStatus(.deniedExplicitly, for: pattern)
            }
        }
        if every, let web = try? WKWebExtension.MatchPattern(string: "*://*/*") {
            context.setPermissionStatus(.grantedExplicitly, for: web)
        }
    }

    /// "install", "update", or nothing to tell: what WebKit calls an install
    /// at every launch is neither.
    func installReason(_ id: String) -> String? {
        if installing.remove(id) != nil { return "install" }
        return loadedBefore.remove(id) != nil ? "update" : nil
    }

    /// What an extension ran into, for whoever looks (Console).
    func note(_ words: String, for id: String) {
        notes[id] = Array(((notes[id] ?? []) + [words]).suffix(40))
        NSLog("Extensions: %@: %@", id, words)
    }
    func noteError(_ words: String, for id: String) { note(words, for: id) }

    /// More than it was given when it was added.
    func ask(_ what: String, context: WKWebExtensionContext) async -> Bool {
        guard let top = Extensions.topController else { return false }
        return await withCheckedContinuation { done in
            let name = context.webExtension.displayName ?? ""
            let alert = UIAlertController(title: String(localized: "“\(name)” asks for more access"), message: what, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in done.resume(returning: false) })
            alert.addAction(UIAlertAction(title: String(localized: "Allow"), style: .default) { _ in done.resume(returning: true) })
            top.present(alert, animated: true)
        }
    }

    /// What a web view needs to show an extension's own page: WebKit loads
    /// those in the extension's configuration only, and nothing else in it.
    func configuration(for url: URL) -> WKWebViewConfiguration? {
        guard url.scheme == Self.scheme, let id = url.host() else { return nil }
        return contexts[id]?.webViewConfiguration
    }

    private func stop(_ id: String) {
        guard let context = contexts.removeValue(forKey: id) else { return }
        ExtensionPanel.shared.close(id)
        ExtensionOffscreen.close(for: id)
        ExtensionDebugger.shared.forget(id)
        try? controller.unload(context)
    }

    private func name(of id: String) -> String { items.first { $0.id == id }?.name ?? id }

    // MARK: adding, removing

    /// A store link or id: downloaded, checked, unpacked, then offered.
    func add(_ text: String) async {
        problem = nil
        guard let id = Crx.id(in: text) else {
            problem = Crx.Refused.notAnID.errorDescription
            return
        }
        adding = true
        addingID = id
        tellStore()
        defer {
            adding = false
            addingID = nil
            tellStore()
        }
        let staged = Self.root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        do {
            let crx = try await Crx.fetch(id)
            let zip = try Crx.verifiedZip(crx, id: id)
            try Zip.extract(zip, into: staged)
            guard FileManager.default.fileExists(atPath: staged.appendingPathComponent("manifest.json").path) else {
                throw Crx.Refused.unpack
            }
            let found = try await WKWebExtension(resourceBaseURL: staged)
            pending = Pending(
                id: id,
                name: found.displayName ?? id,
                version: found.version ?? "",
                wants: Self.describe(found),
                staged: staged
            )
        } catch {
            try? FileManager.default.removeItem(at: staged)
            problem = error.localizedDescription
        }
    }

    func confirm() async {
        guard let offer = pending else { return }
        pending = nil
        stop(offer.id)
        let files = FileManager.default
        let folder = Self.folder(for: offer.id)
        try? files.removeItem(at: folder)
        do { try files.moveItem(at: offer.staged, to: folder) } catch {
            problem = error.localizedDescription
            return
        }
        let item = Item(id: offer.id, name: offer.name, version: offer.version, on: true)
        if let index = items.firstIndex(where: { $0.id == offer.id }) { items[index] = item } else { items.append(item) }
        save()
        installing.insert(offer.id)
        await start(offer.id)
        tellStore()
    }

    func cancel() {
        if let offer = pending { try? FileManager.default.removeItem(at: offer.staged) }
        pending = nil
    }

    func remove(_ id: String) {
        stop(id)
        try? FileManager.default.removeItem(at: Self.folder(for: id))
        PanelCookies.forget(id)
        items.removeAll { $0.id == id }
        save()
        tellStore()
    }

    /// Tells the store page in front what is installed and what is on its
    /// way, so its button says "Added to Search" or "Adding…".
    func tellStore() {
        guard let tab = browser?.active, let url = tab.address, Crx.storeID(of: url) != nil else { return }
        let state: [String: Any] = ["installed": items.map(\.id), "busy": addingID.map { [$0] } ?? []]
        guard let data = try? JSONSerialization.data(withJSONObject: state),
              let json = String(data: data, encoding: .utf8)
        else { return }
        tab.web.evaluateJavaScript("window.__searchStore && window.__searchStore.state(\(json))", in: nil, in: .page) { _ in }
    }

    func set(_ id: String, on: Bool) async {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].on = on
        save()
        if on { await start(id) } else { stop(id) }
    }

    func icon(of id: String) -> UIImage? {
        contexts[id]?.webExtension.icon(for: CGSize(width: 40, height: 40))
    }

    /// Its button, as in Chrome's toolbar: its panel when it asked for its
    /// button to open it, else the popup over the page in front or a press
    /// it hears; its options page when it has no button.
    func open(_ id: String) {
        guard let context = contexts[id], let browser else { return }
        if ExtensionShims.panelOnClick.contains(id), let url = ExtensionShims.actionPanel(context, over: browser.activeID) {
            ExtensionPanel.shared.show(url, of: context)
            return
        }
        if let tab = browser.active, !tab.isPrivate, context.action(for: adapter(for: tab)) != nil {
            // A press for a background that isn't up is lost: up first.
            Task {
                if context.webExtension.hasBackgroundContent { try? await context.loadBackgroundContent() }
                context.performAction(for: adapter(for: tab))
            }
        } else if let options = context.optionsPageURL {
            browser.openPage(options)
        }
    }

    /// What it asks for, in a sentence.
    static func describe(_ found: WKWebExtension) -> String {
        var parts: [String] = []
        let patterns = found.allRequestedMatchPatterns
        if patterns.contains(where: { $0.matchesAllHosts || $0.matchesAllURLs }) {
            parts.append(String(localized: "read and change every site you visit"))
        } else if !patterns.isEmpty {
            let hosts = Set(patterns.compactMap { $0.host }).sorted().prefix(4)
            parts.append(String(localized: "read and change \(hosts.joined(separator: ", "))"))
        }
        let permissions = found.requestedPermissions
        // Not one WebKit knows: read from the manifest as it is.
        if (found.manifest["permissions"] as? [Any] ?? []).contains(where: { $0 as? String == "debugger" }) {
            parts.append(String(localized: "act on the pages you have open: see them, press and type"))
        }
        if permissions.contains(.tabs) { parts.append(String(localized: "see your tabs")) }
        if permissions.contains(.cookies) { parts.append(String(localized: "read cookies")) }
        if permissions.contains(.declarativeNetRequest) { parts.append(String(localized: "block or change requests")) }
        if permissions.contains(.storage) { parts.append(String(localized: "keep its own data")) }
        return parts.isEmpty ? String(localized: "It asks for nothing special.") : String(localized: "It will be able to \(parts.joined(separator: ", ")).")
    }

    // MARK: tabs

    func adapter(for tab: Tab) -> ExtensionTab {
        if let known = adapters[tab.id] { return known }
        let made = ExtensionTab(tab: tab, owner: self)
        adapters[tab.id] = made
        return made
    }

    /// The tabs an extension sees: never private ones.
    var visibleTabs: [Tab] { browser?.tabs.filter { !$0.isPrivate } ?? [] }

    /// Tabs opening, closing and coming to the front, told to WebKit.
    private func follow() {
        watching.removeAll()
        tabWatching.removeAll()
        guard let browser else { return }
        known = visibleTabs.map(\.id)
        controller.didOpenWindow(window)
        for tab in visibleTabs {
            controller.didOpenTab(adapter(for: tab))
            track(tab)
        }
        browser.$tabs
            .receive(on: RunLoop.main)
            .sink { [weak self] tabs in
                guard let self else { return }
                let now = tabs.filter { !$0.isPrivate }
                let ids = now.map(\.id)
                for tab in now where !self.known.contains(tab.id) {
                    self.controller.didOpenTab(self.adapter(for: tab))
                    self.track(tab)
                }
                for gone in self.known where !ids.contains(gone) {
                    self.tabWatching.removeValue(forKey: gone)
                    if let adapter = self.adapters.removeValue(forKey: gone) {
                        self.controller.didCloseTab(adapter, windowIsClosing: false)
                    }
                }
                self.known = ids
            }
            .store(in: &watching)
        browser.$activeID
            .receive(on: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self, let tab = self.browser?.active, !tab.isPrivate else { return }
                self.controller.didActivateTab(self.adapter(for: tab), previousActiveTab: nil)
            }
            .store(in: &watching)
    }

    /// Deliver tabs.onUpdated after @Published has written its new value.
    /// Private tabs are neither registered nor observed by extensions.
    private func track(_ tab: Tab) {
        guard !tab.isPrivate, tabWatching[tab.id] == nil else { return }
        let changes: [AnyPublisher<WKWebExtension.TabChangedProperties, Never>] = [
            tab.$address.dropFirst().map { _ in .URL }.eraseToAnyPublisher(),
            tab.$loading.dropFirst().map { _ in .loading }.eraseToAnyPublisher(),
            tab.$title.dropFirst().map { _ in .title }.eraseToAnyPublisher(),
        ]
        tabWatching[tab.id] = Publishers.MergeMany(changes)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] properties in
                guard let self, let tab, self.known.contains(tab.id) else { return }
                self.controller.didChangeTabProperties(properties, for: self.adapter(for: tab))
            }
    }

    static var topController: UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }
}

@available(iOS 18.4, *)
extension Extensions: WKWebExtensionControllerDelegate {
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        browser == nil ? [] : [window]
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        browser == nil ? nil : window
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration, for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionTab)? {
        guard let browser else { return nil }
        let url = configuration.url ?? URL(string: "about:blank")!
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme != "javascript", scheme != "file" else {
            throw NSError(domain: "Search", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot open a \(scheme): URL."])
        }
        dismissPopup()
        ExtensionPanel.shared.lower()
        if configuration.shouldBeActive || url.scheme == Extensions.scheme {
            browser.openPage(url)
            return browser.active.map(adapter(for:))
        }
        browser.open(url, private: false, behind: true)
        return browser.tabs.last { $0.address == url }.map(adapter(for:))
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext) async throws {
        guard let url = extensionContext.optionsPageURL else { return }
        dismissPopup()
        ExtensionPanel.shared.lower()
        browser?.openPage(url)
    }

    /// One window here: a new one is a tab in it.
    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration, for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionWindow)? {
        guard let browser else { return nil }
        dismissPopup()
        ExtensionPanel.shared.lower()
        for url in configuration.tabURLs where !["javascript", "file"].contains(url.scheme?.lowercased() ?? "") { browser.openPage(url) }
        return window
    }

    /// The script's line to the app (ExtensionShims). There are no other
    /// apps for an extension to speak to on iOS.
    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?, for extensionContext: WKWebExtensionContext) async throws -> Any? {
        // Asked to fail, in these words, so WebKit sets runtime.lastError.
        if applicationIdentifier == ExtensionShims.application + ".error" {
            let words = (message as? [String: Any])?["message"] as? String ?? "Unknown error"
            throw NSError(domain: "Search", code: 4, userInfo: [NSLocalizedDescriptionKey: words])
        }
        guard applicationIdentifier == nil || applicationIdentifier == ExtensionShims.application else {
            throw NSError(domain: "Search", code: 3, userInfo: [NSLocalizedDescriptionKey: "Specified native messaging host not found."])
        }
        return await ExtensionShims.answer(message, from: extensionContext, owner: self)
    }

    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort, for extensionContext: WKWebExtensionContext) async throws {
        if port.applicationIdentifier == ExtensionFetch.name {
            ExtensionFetch.connect(port, from: extensionContext)
            return
        }
        // The ports the script listens on for news: none comes here.
        if port.applicationIdentifier?.hasPrefix(ExtensionShims.application) == true {
            port.messageHandler = { [weak port] _, _ in port?.sendMessage(["listening": true]) { _ in } }
            kept.append(port)
            return
        }
        throw NSError(domain: "Search", code: 3, userInfo: [NSLocalizedDescriptionKey: "Specified native messaging host not found."])
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.Permission>, Date?) {
        (permissions, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<URL>, Date?) {
        (urls, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.MatchPattern>, Date?) {
        (matchPatterns, nil)
    }

    /// Its popup, as a sheet over the page.
    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for context: WKWebExtensionContext) async throws {
        guard let popup = action.popupViewController, let top = Extensions.topController else {
            throw NSError(domain: "Search", code: 2, userInfo: [NSLocalizedDescriptionKey: "The popup can't be shown."])
        }
        if let sheet = popup.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        self.popup = popup
        popupOwner = context.uniqueIdentifier
        top.present(popup, animated: true)
    }

    /// As in Chrome: a popup goes once it has opened a page.
    private func dismissPopup() {
        popup?.dismiss(animated: true)
        popup = nil
    }
}

// MARK: - tab and window, as an extension sees them

@available(iOS 18.4, *)
final class ExtensionTab: NSObject, WKWebExtensionTab {
    weak var tab: Tab?
    unowned let owner: Extensions

    init(tab: Tab, owner: Extensions) {
        self.tab = tab
        self.owner = owner
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        MainActor.assumeIsolated { owner.window }
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        MainActor.assumeIsolated {
            guard let tab else { return NSNotFound }
            return owner.visibleTabs.firstIndex { $0.id == tab.id } ?? NSNotFound
        }
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        MainActor.assumeIsolated { tab?.isPrivate == true ? nil : tab?.web }
    }

    func title(for context: WKWebExtensionContext) -> String? {
        MainActor.assumeIsolated { tab?.title }
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        MainActor.assumeIsolated { tab?.address }
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        MainActor.assumeIsolated { tab?.id == owner.browser?.activeID }
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        MainActor.assumeIsolated { tab?.web.isLoading != true }
    }

    func isPinned(for context: WKWebExtensionContext) -> Bool {
        MainActor.assumeIsolated { tab?.pin != nil }
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext) async throws {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme != "javascript", scheme != "file" else {
            throw NSError(domain: "Search", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot open a \(scheme): URL."])
        }
        await MainActor.run {
            guard let tab else { return }
            // A web page's view can't go to an extension's, nor back.
            if scheme == Extensions.scheme || tab.address?.scheme == Extensions.scheme {
                owner.browser?.openPage(url)
            } else {
                tab.web.load(URLRequest(url: url))
            }
        }
    }

    func activate(for context: WKWebExtensionContext) async throws {
        await MainActor.run {
            if let tab { owner.browser?.select(tab) }
        }
    }

    func close(for context: WKWebExtensionContext) async throws {
        await MainActor.run {
            if let tab { owner.browser?.close(tab) }
        }
    }
}

@available(iOS 18.4, *)
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    unowned let owner: Extensions

    init(owner: Extensions) {
        self.owner = owner
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        MainActor.assumeIsolated { owner.visibleTabs.map(owner.adapter(for:)) }
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        MainActor.assumeIsolated {
            guard let tab = owner.browser?.active, !tab.isPrivate else { return nil }
            return owner.adapter(for: tab)
        }
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .fullscreen }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
}

// MARK: - the sheet

/// What holding the seal opens: the extensions, and adding one.
@available(iOS 18.4, *)
struct ExtensionsSheet: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var extensions = Extensions.shared
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if extensions.items.isEmpty {
                        Text("No extensions yet.").foregroundStyle(.secondary)
                    }
                    ForEach(extensions.items) { item in
                        // Its own button: a tap on a row with a switch in it
                        // could turn the switch instead of opening it.
                        HStack(spacing: 12) {
                            Button {
                                dismiss()
                                // Once this sheet is down, so what it shows can come up.
                                let start = !item.on
                                Task {
                                    if start { await extensions.set(item.id, on: true) }
                                    try? await Task.sleep(for: .milliseconds(450))
                                    extensions.open(item.id)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Group {
                                        if let icon = extensions.icon(of: item.id) {
                                            Image(uiImage: icon).resizable()
                                        } else {
                                            Image(systemName: "puzzlepiece.extension").resizable().scaledToFit().padding(6).foregroundStyle(.secondary)
                                        }
                                    }
                                    .frame(width: 32, height: 32)
                                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name).lineLimit(1).foregroundStyle(Color.primary)
                                        Text(item.version)
                                            .font(.caption).foregroundStyle(Color.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            Toggle("", isOn: Binding(
                                get: { item.on },
                                set: { on in Task { await extensions.set(item.id, on: on) } }
                            ))
                            .labelsHidden()
                            .fixedSize()
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { extensions.remove(item.id) }
                        }
                    }
                } header: {
                    Text("Extensions")
                } footer: {
                    Text("Tap one to open it on this page. Swipe to remove. They never run in private tabs.")
                }

                Section {
                    TextField("Chrome Web Store link or id", text: $link)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button {
                        Task { await extensions.add(link) }
                    } label: {
                        HStack {
                            Label("Add", systemImage: "plus")
                            Spacer()
                            if extensions.adding { ProgressView() }
                        }
                    }
                    .disabled(extensions.adding || link.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let problem = extensions.problem {
                        Text(problem).foregroundStyle(.red)
                    }
                    Button {
                        dismiss()
                        browser.open(URL(string: "https://chromewebstore.google.com")!)
                    } label: {
                        Label("Open the Chrome Web Store", systemImage: "safari")
                    }
                } header: {
                    Text("Add from the Chrome Web Store")
                } footer: {
                    Text("Open one in the store and tap Add to Search, or paste its link here. Extensions run on WebKit's engine, the one Safari uses: most work, some Chrome-only features may not.")
                }
            }
            .navigationTitle("Extensions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert(
                extensions.pending.map { String(localized: "Add “\($0.name)”?") } ?? "",
                // Dismissed by its buttons only: the binding is set before
                // a button's action runs, so cancelling here undid Add.
                isPresented: Binding(get: { extensions.pending != nil }, set: { _ in }),
                presenting: extensions.pending
            ) { _ in
                Button("Add") { Task { await extensions.confirm(); link = "" } }
                Button("Cancel", role: .cancel) { extensions.cancel() }
            } message: { offer in
                Text(offer.wants)
            }
        }
        .onAppear {
            // A store page in front: its link, ready to add.
            if link.isEmpty, let url = browser.active?.address, url.host()?.contains("chromewebstore.google.com") == true, Crx.id(in: url.absoluteString) != nil {
                link = url.absoluteString
            }
        }
    }
}

// MARK: - the store's own button

/// The Chrome Web Store sees a phone and offers "Add to desktop" (on a Mac,
/// a grey "Add to Chrome"). On its pages that button gives way to an "Add to
/// Search" one in the same place and shape, which installs here. What gets
/// installed is read from the tab's own address, never from the page; the
/// page only asks, and the usual confirmation still comes before anything
/// is added. (The Mac's StoreRelay, made for the phone's store.)
final class StoreRelay: NSObject, WKScriptMessageHandler {
    static let host = "chromewebstore.google.com"
    /// Safari on a Mac, which is what WebKit is there.
    static let agent: String = {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(os.majorVersion).\(os.minorVersion) Safari/605.1.15"
    }()

    static let name = "searchStore"

    weak var browser: Browser?

    init(_ browser: Browser) {
        self.browser = browser
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        let web = message.webView
        MainActor.assumeIsolated {
            guard let browser, let web, let tab = browser.tabs.first(where: { $0.web === web }) else { return }
            guard #available(iOS 18.4, *) else { return }
            if body["add"] != nil, let url = tab.address, let id = Crx.storeID(of: url) {
                ExtensionPanel.shared.hide { browser.showingExtensions = true }
                Task { await Extensions.shared.add(id) }
            }
            if body["placed"] != nil { Extensions.shared.tellStore() }
        }
    }

    /// Main frame, every page, returning at once anywhere but the store. Its
    /// markup is generated and its class names change, so nothing here leans
    /// on them: the store's button is the one whose words say add, and to
    /// Chrome or to a computer, in any of the usual languages.
    static let script = #"""
    (function () {
      if (location.hostname !== 'chromewebstore.google.com' || window.__searchStore) return;
      // Laid out for a computer, it runs off a phone's side: the filters'
      // column goes and what's left fits the width. Said by the page's
      // meaning, as its class names change.
      try {
        var sheet = new CSSStyleSheet();
        sheet.replaceSync('@media (max-width: 900px) {' +
          'html, body { min-width: 0 !important; overflow-x: hidden !important; }' +
          'main { min-width: 0 !important; max-width: none !important; width: auto !important; box-sizing: border-box !important; margin: 0 !important; padding-left: 16px !important; padding-right: 16px !important; }' +
          ':has(> main) { min-width: 0 !important; }' +
          'section:has(+ main) { display: none !important; }' +
          'main > *, main section { min-width: 0 !important; max-width: 100% !important; box-sizing: border-box !important; }' +
          'main img { max-width: 100%; }' +
          'main a[href*="detail/"] + div > img { flex: 0 0 auto !important; max-width: 110px !important; max-height: 110px !important; height: auto !important; object-fit: contain; align-self: flex-start; }' +
          'main a[href*="detail/"] + div > div:first-child:has(> img) { flex: 0 0 auto !important; max-width: 110px !important; max-height: 110px !important; overflow: hidden; }' +
          'main :has(> * > a[href*="detail/"] + div > img), main :has(> * > * > a[href*="detail/"] + div > img) { grid-template-columns: repeat(2, minmax(0, 1fr)) !important; }' +
          '}');
        document.adoptedStyleSheets = Array.from(document.adoptedStyleSheets).concat(sheet);
      } catch (e) {}
      var es = /^es/i.test(document.documentElement.lang || navigator.language || '');
      var words = es
        ? { add: 'Añadir a Search', adding: 'Añadiendo…', added: 'Añadido a Search' }
        : { add: 'Add to Search', adding: 'Adding…', added: 'Added to Search' };
      var state = { installed: [], busy: [] };
      var install = /(add|añadir|agregar|ajouter|hinzuf|aggiungi|adicionar|toevoegen)/i;
      var where = /(chrome|desktop|ordenador|computadora|computer|escritorio|ordinateur|rechner|computador)/i;

      function pageID() {
        var m = location.pathname.match(/\/detail\/(?:[^\/]+\/)?([a-p]{32})/);
        return m ? m[1] : null;
      }

      function theirs() {
        var buttons = document.querySelectorAll('button');
        for (var i = 0; i < buttons.length; i++) {
          var b = buttons[i];
          if (b.dataset.search) continue;
          var said = (b.textContent || '') + ' ' + (b.getAttribute('aria-label') || '');
          if (install.test(said) && where.test(said) && b.getClientRects().length) return b;
        }
        return null;
      }

      // The "Switch to Chrome" card, known by the Chrome logo it carries.
      function hidePromo() {
        var cards = document.querySelectorAll('[role="dialog"]');
        for (var c = 0; c < cards.length; c++) {
          if (!cards[c].dataset.search && cards[c].querySelector('img[src*="productlogos/chrome"]')) {
            cards[c].style.display = 'none';
            cards[c].dataset.search = 'promo';
          }
        }
        // And the strip above a listing that offers to install Chrome: all
        // of it that isn't the listing.
        var offers = document.querySelectorAll('main button, main a');
        for (var o = 0; o < offers.length; o++) {
          var text = (offers[o].textContent || '').replace(/\s+/g, ' ').trim();
          if (text.length > 24 || !/^(install|instal|installer|installa|instalar)\w* (google )?chrome$|^chrome installieren$/i.test(text)) continue;
          var strip = offers[o];
          while (strip.parentElement && strip.parentElement.tagName !== 'MAIN' && !strip.parentElement.querySelector('h1')) strip = strip.parentElement;
          if (strip.parentElement && strip.parentElement.querySelector('h1')) strip.style.display = 'none';
        }
      }

      // The words only, so the button keeps the store's own shape and colour.
      function label(button, text) {
        var walker = document.createTreeWalker(button, NodeFilter.SHOW_TEXT);
        var node, last = null;
        while ((node = walker.nextNode())) { if (node.nodeValue.trim()) last = node; }
        if (last) last.nodeValue = text; else button.textContent = text;
      }

      function render(ours) {
        var id = pageID();
        var installed = !!id && state.installed.indexOf(id) >= 0;
        var busy = !!id && state.busy.indexOf(id) >= 0;
        label(ours, installed ? words.added : (busy ? words.adding : words.add));
        ours.disabled = installed || busy;
        ours.style.opacity = installed || busy ? '0.6' : '';
      }

      function renderAll() {
        var mine = document.querySelectorAll('button[data-search="add"]');
        for (var i = 0; i < mine.length; i++) render(mine[i]);
      }

      function mend() {
        hidePromo();
        if (!pageID()) return;
        var original = theirs();
        if (original && original.parentNode) {
          var ours = original.cloneNode(true);
          ['disabled', 'jsaction', 'jscontroller', 'jsname', 'jslog', 'aria-describedby', 'aria-label'].forEach(function (name) {
            ours.removeAttribute(name);
          });
          ours.dataset.search = 'add';
          original.dataset.search = 'theirs';
          original.style.display = 'none';
          original.parentNode.insertBefore(ours, original.nextSibling);
          window.webkit.messageHandlers.searchStore.postMessage({ placed: pageID() });
        }
        renderAll();
      }

      // Caught on the window, before the store's own handlers see the click.
      window.addEventListener('click', function (e) {
        var mine = e.target && e.target.closest && e.target.closest('button[data-search="add"]');
        if (!mine) return;
        e.preventDefault();
        e.stopImmediatePropagation();
        if (!mine.disabled) window.webkit.messageHandlers.searchStore.postMessage({ add: true });
      }, true);

      window.__searchStore = {
        state: function (next) { state = next || state; renderAll(); }
      };

      // The store is one page that rewrites itself: whatever it redraws, mend again.
      var queued = false;
      new MutationObserver(function () {
        if (queued) return;
        queued = true;
        setTimeout(function () { queued = false; mend(); }, 60);
      }).observe(document.documentElement, { childList: true, subtree: true });
      mend();
    })();
    """#
}
