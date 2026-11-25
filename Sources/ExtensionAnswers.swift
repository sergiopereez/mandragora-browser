import AVFoundation
import NaturalLanguage
import SwiftUI
import UserNotifications
import WebKit

// What the script asks the app for (ExtensionShim.js), and the answers. From
// the Mac's ExtensionShims.run, for one window.

@available(iOS 18.4, *)
extension ExtensionShims {
    /// Remembered per extension: the side panel it set, and whether its
    /// button should open it.
    @MainActor static var panelPath: [String: String] = [:]
    @MainActor static var panelOnClick: Set<String> = []
    @MainActor static var panelOff: Set<String> = []
    @MainActor static var panelTabs: [String: [Int: (path: String?, enabled: Bool?)]] = [:]
    @MainActor static var panelTabIDs: [String: [Int: Tab.ID]] = [:]

    /// Tab groups an extension makes: kept for it, nothing shows them.
    /// Claude works only on tabs in a group of its own.
    struct Group {
        var title = ""
        var color = "grey"
        var collapsed = false
        var tabs: Set<Tab.ID> = []
    }
    @MainActor static var groups: [Int: Group] = [:]
    @MainActor private static var groupCount = 0
    @MainActor private static let speaker = AVSpeechSynthesizer()

    @MainActor static func answer(_ message: Any, from context: WKWebExtensionContext, owner: Extensions) async -> Any? {
        guard let body = message as? [String: Any], let api = body["api"] as? String else {
            return ["error": "Not a Search message"]
        }
        do {
            return ["value": try await run(api, body["args"] as? [Any] ?? [], context: context, owner: owner) ?? NSNull()]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    /// The families whose answers leave the extension's own origin, by the
    /// permission its manifest has to name. The script runs beside the
    /// extension's own code, so the check that counts is here.
    private static let gates: [String: String] = [
        "history": "history", "downloads": "downloads", "sessions": "sessions", "topSites": "topSites",
        "browsingData": "browsingData", "userScripts": "userScripts", "identity": "identity", "search": "search",
        "notifications": "notifications", "idle": "idle", "power": "power", "tts": "tts", "tabGroups": "tabGroups",
        "fontSettings": "fontSettings", "debugger": "debugger", "system.cpu": "system.cpu",
        "system.memory": "system.memory", "system.storage": "system.storage", "system.display": "system.display",
    ]

    static func family(of api: String) -> String {
        let parts = api.split(separator: ".")
        return parts.prefix(parts.first == "system" ? 2 : 1).joined(separator: ".")
    }

    @MainActor static func allowed(_ id: String, context: WKWebExtensionContext) -> Set<String> {
        let asked = (context.webExtension.manifest["permissions"] as? [Any] ?? []).compactMap { $0 as? String }
        return Set(asked + (Store.settings.stringArray(forKey: "extensions.granted.\(id)") ?? []))
    }

    /// A tab as the script names it: its place in the row extensions see,
    /// checked against its address when one is given.
    @MainActor static func located(_ place: Any?, owner: Extensions) -> Tab? {
        let spec = place as? [String: Any]
        guard let index = (place as? NSNumber)?.intValue ?? (spec?["i"] as? NSNumber)?.intValue else { return nil }
        let row = owner.visibleTabs
        guard row.indices.contains(index) else { return nil }
        return row[index]
    }

    @MainActor private static func chromeGroup(_ number: Int, _ group: Group) -> [String: Any] {
        ["id": number, "title": group.title, "collapsed": group.collapsed, "color": group.color, "windowId": 1, "shared": false]
    }

    /// Groups whose tabs are still there.
    @MainActor private static func listed(_ owner: Extensions) -> [(Int, Group)] {
        let open = Set(owner.visibleTabs.map(\.id))
        for (number, group) in groups {
            let left = group.tabs.intersection(open)
            if left.isEmpty { groups[number] = nil } else if left != group.tabs { groups[number]?.tabs = left }
        }
        return groups.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    static func defaultPanel(_ context: WKWebExtensionContext) -> String? {
        (context.webExtension.manifest["side_panel"] as? [String: Any])?["default_path"] as? String
    }

    /// One of the extension's own pages, from the path it gave, which can
    /// carry a query (Claude's panel names its tab). Never anywhere else.
    static func page(_ path: String, in context: WKWebExtensionContext) -> URL? {
        let base = context.baseURL
        guard let url = URL(string: path.trimmingCharacters(in: CharacterSet(charactersIn: "/")), relativeTo: base)?.absoluteURL,
              url.scheme == base.scheme, url.host() == base.host() else { return nil }
        return url
    }

    /// The panel an extension's button opens over this tab, if it asked for
    /// its button to open it.
    @MainActor static func actionPanel(_ context: WKWebExtensionContext, over tab: Tab.ID?) -> URL? {
        let id = context.uniqueIdentifier
        let number = tab.flatMap { tab in panelTabIDs[id]?.filter { $0.value == tab }.map(\.key).max() }
        let own = number.flatMap { panelTabs[id]?[$0] }
        guard own?.enabled ?? !panelOff.contains(id),
              let path = own?.path ?? panelPath[id] ?? defaultPanel(context) else { return nil }
        return page(path, in: context)
    }

    @MainActor private static func run(_ api: String, _ args: [Any], context: WKWebExtensionContext, owner: Extensions) async throws -> Any? {
        guard let browser = owner.browser else { throw Unsupported(what: "No browser window") }
        let first = args.first
        let id = context.uniqueIdentifier

        if api.hasPrefix("setting.") {
            let parts = api.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            let key = "extensions.settings.\(id)"
            var mine = Store.settings.dictionary(forKey: key) ?? [:]
            switch parts[0] {
            case "setting.set": mine[parts[1]] = (first as? [String: Any])?["value"]
            case "setting.clear": mine[parts[1]] = nil
            default:
                return ["value": mine[parts[1]] ?? NSNull(),
                        "levelOfControl": mine[parts[1]] != nil ? "controlled_by_this_extension" : "controllable_by_this_extension"]
            }
            Store.settings.set(mine, forKey: key)
            return nil
        }
        if api == "tabs.describe", !context.hasPermission(.tabs), !context.hasPermission(.activeTab) {
            throw Unsupported(what: "The extension never asked for “tabs”")
        }
        if let needed = gates[family(of: api)], !allowed(id, context: context).contains(needed) {
            throw Unsupported(what: "The extension never asked for “\(needed)”")
        }

        switch api {
        // MARK: the debugger
        case _ where api.hasPrefix("debugger."):
            return try await ExtensionDebugger.shared.answer(api, args, for: id, owner: owner)

        // MARK: history
        case "history.search":
            let spec = first as? [String: Any] ?? [:]
            let text = spec["text"] as? String ?? ""
            let limit = spec["maxResults"] as? Int ?? 100
            let found = text.isEmpty ? browser.history.top(limit) : browser.history.suggestions(for: text, limit: limit)
            return found.map { ["id": $0.id, "url": $0.url.absoluteString, "title": $0.title, "visitCount": 1, "typedCount": 0,
                                "lastVisitTime": Date().timeIntervalSince1970 * 1000] as [String: Any] }
        case "history.addUrl":
            if let url = ((first as? [String: Any])?["url"] as? String).flatMap(URL.init(string:)) { browser.history.record(url, title: "") }
            return nil
        case "history.getVisits", "topSites.get", "sessions.getRecentlyClosed", "sessions.getDevices":
            return [Any]()

        // MARK: downloads
        case "downloads.download":
            guard let url = ((first as? [String: Any])?["url"] as? String).flatMap(URL.init(string:)) else { throw Unsupported(what: "No url to download") }
            guard let web = browser.active?.isPrivate == false ? browser.active?.web : owner.visibleTabs.first?.web else {
                throw Unsupported(what: "No page to download through")
            }
            let download = await web.startDownload(using: URLRequest(url: url))
            Downloads.shared.take(download, from: browser)
            return 1
        case "downloads.search", "downloads.erase":
            return [Any]()

        // MARK: the side panel
        case "sidePanel.setOptions":
            let options = first as? [String: Any] ?? [:]
            if let tab = options["tabId"] as? Int {
                var kept = panelTabs[id]?[tab] ?? (nil, nil)
                if let path = options["path"] as? String { kept.path = path }
                if let enabled = options["enabled"] as? Bool { kept.enabled = enabled }
                panelTabs[id, default: [:]][tab] = kept
            } else {
                if let path = options["path"] as? String { panelPath[id] = path }
                if let enabled = options["enabled"] as? Bool {
                    if enabled { panelOff.remove(id) } else { panelOff.insert(id) }
                }
            }
            return nil
        case "sidePanel.getOptions":
            let tab = (first as? [String: Any])?["tabId"] as? Int
            let own = tab.flatMap { panelTabs[id]?[$0] }
            return ["enabled": own?.enabled ?? !panelOff.contains(id),
                    "path": own?.path ?? panelPath[id] ?? defaultPanel(context) ?? ""]
        case "sidePanel.setPanelBehavior":
            if let on = (first as? [String: Any])?["openPanelOnActionClick"] as? Bool {
                if on { panelOnClick.insert(id) } else { panelOnClick.remove(id) }
            }
            return nil
        case "sidePanel.getPanelBehavior":
            return ["openPanelOnActionClick": panelOnClick.contains(id)]
        case "sidePanel.placed":
            if let number = first as? Int, let tab = located(args.dropFirst().first, owner: owner) {
                panelTabIDs[id, default: [:]][number] = tab.id
            }
            return nil
        case "sidePanel.open":
            let tab = (first as? [String: Any])?["tabId"] as? Int
            let own = tab.flatMap { panelTabs[id]?[$0] }
            guard own?.enabled ?? !panelOff.contains(id),
                  let path = own?.path ?? panelPath[id] ?? defaultPanel(context), let url = page(path, in: context)
            else { throw Unsupported(what: "No active side panel for this extension") }
            ExtensionPanel.shared.show(url, of: context)
            return nil
        case "sidePanel.close":
            ExtensionPanel.shared.close(id)
            return nil

        // MARK: offscreen
        case "offscreen.createDocument":
            guard let path = (first as? [String: Any])?["url"] as? String else { throw Unsupported(what: "No page for the offscreen document") }
            try await ExtensionOffscreen.create(path, for: context)
            return nil
        case "offscreen.closeDocument":
            ExtensionOffscreen.close(for: id)
            return nil
        case "offscreen.hasDocument":
            return ExtensionOffscreen.hasDocument(for: id)
        case "offscreen.sendMessage":
            return ["handled": false]

        // MARK: fonts
        case "fontSettings.getFontList":
            return UIFont.familyNames.map { ["fontId": $0, "displayName": $0] }
        case "fontSettings.getFont": return ["fontId": "", "levelOfControl": "not_controllable"]
        case "fontSettings.getDefaultFontSize": return ["pixelSize": 16, "levelOfControl": "not_controllable"]
        case "fontSettings.getDefaultFixedFontSize": return ["pixelSize": 13, "levelOfControl": "not_controllable"]
        case "fontSettings.getMinimumFontSize": return ["pixelSize": 0, "levelOfControl": "not_controllable"]
        case _ where api.hasPrefix("fontSettings.set") || api.hasPrefix("fontSettings.clear"): return nil

        // MARK: itself
        case "management.getSelf", "management.get":
            let found = context.webExtension
            return ["id": id, "name": found.displayName ?? "", "shortName": found.displayShortName ?? "",
                    "version": found.version ?? "", "description": found.displayDescription ?? "", "enabled": true,
                    "type": "extension", "installType": "normal", "mayDisable": true, "offlineEnabled": true, "isApp": false,
                    "hostPermissions": [Any](), "permissions": [Any]()] as [String: Any]
        case "management.getAll": return [Any]()
        case "i18n.detectLanguage":
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(first as? String ?? "")
            let guesses = recognizer.languageHypotheses(withMaximum: 3)
            return ["isReliable": (guesses.values.max() ?? 0) > 0.6,
                    "languages": guesses.sorted { $0.value > $1.value }.map { ["language": $0.key.rawValue, "percentage": Int($0.value * 100)] as [String: Any] }]
        case "runtime.getContexts":
            let filter = first as? [String: Any] ?? [:]
            let types = filter["contextTypes"] as? [String]
            let urls = filter["documentUrls"] as? [String]
            var found: [[String: Any]] = []
            func add(_ type: String, _ url: URL?) {
                guard types == nil || types!.contains(type) else { return }
                let address = url?.absoluteString ?? ""
                guard urls == nil || urls!.contains(address) else { return }
                found.append(["contextType": type, "contextId": "\(id)-\(type)", "tabId": -1, "windowId": -1,
                              "frameId": type == "BACKGROUND" ? -1 : 0, "documentUrl": address,
                              "documentOrigin": url.map { "\($0.scheme ?? "")://\($0.host() ?? "")" } ?? "", "incognito": false])
            }
            if context.webExtension.hasBackgroundContent { add("BACKGROUND", context.baseURL) }
            if owner.popupID == id { add("POPUP", context.baseURL) }
            if let url = ExtensionPanel.shared.address(of: id) { add("SIDE_PANEL", url) }
            if let url = ExtensionOffscreen.url(for: id) { add("OFFSCREEN_DOCUMENT", url) }
            return found
        case "clients.pages":
            var pages: [[String: Any]] = []
            for tab in owner.visibleTabs {
                guard let url = tab.address, url.scheme == Extensions.scheme, url.host() == id else { continue }
                let shown = tab.id == browser.activeID
                pages.append(["id": tab.id.uuidString, "url": url.absoluteString, "visible": shown, "focused": shown])
            }
            if let url = ExtensionPanel.shared.address(of: id) { pages.append(["id": "panel", "url": url.absoluteString, "visible": true, "focused": true]) }
            if let url = ExtensionOffscreen.url(for: id) { pages.append(["id": "offscreen", "url": url.absoluteString, "visible": false, "focused": false]) }
            return pages

        // MARK: notifications
        case "notifications.create":
            let named = first as? String
            let options = (named == nil ? first : (args.count > 1 ? args[1] : nil)) as? [String: Any] ?? [:]
            let key = named.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
            let title = options["title"] as? String ?? context.webExtension.displayName ?? ""
            let words = options["message"] as? String ?? ""
            // In the app, as a word at the foot; the phone's own only when
            // you are elsewhere and had already said yes to them.
            if UIApplication.shared.applicationState == .active {
                browser.say(words.isEmpty ? title : "\(title): \(words)")
            } else {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = words
                try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "\(id).\(key)", content: content, trigger: nil))
            }
            return key
        case "notifications.clear": return true
        case "notifications.getAll": return [String: Any]()
        case "notifications.getPermissionLevel": return "granted"
        case "notifications.update": return false

        // MARK: speech
        case "tts.speak":
            let words = AVSpeechUtterance(string: first as? String ?? "")
            if let lang = (args.dropFirst().first as? [String: Any])?["lang"] as? String { words.voice = AVSpeechSynthesisVoice(language: lang) }
            speaker.speak(words)
            return nil
        case "tts.stop": speaker.stopSpeaking(at: .immediate); return nil
        case "tts.pause": speaker.pauseSpeaking(at: .word); return nil
        case "tts.resume": speaker.continueSpeaking(); return nil
        case "tts.isSpeaking": return speaker.isSpeaking
        case "tts.getVoices":
            return AVSpeechSynthesisVoice.speechVoices().map { ["voiceName": $0.name, "lang": $0.language, "remote": false, "eventTypes": ["start", "end"]] as [String: Any] }

        // MARK: the background
        case "background.wake":
            guard context.webExtension.hasBackgroundContent else { return nil }
            try? await context.loadBackgroundContent()
            return nil
        case "background.installReason":
            return owner.installReason(id) ?? NSNull()
        case "background.observe", "background.unobserve", "background.revive", "memory.rulesBuilt":
            return nil
        case "dnr.session":
            switch first as? String {
            case "spilled": owner.sessionSpilled.insert(id); return nil
            case "given", "kept":
                if first as? String == "given" { owner.sessionGiven.insert(id) }
                return nil
            default:
                return ["given": owner.sessionGiven.contains(id),
                        "age": owner.loadedAt[id].map { Date().timeIntervalSince($0) } ?? 0,
                        "spilled": owner.sessionSpilled.contains(id)] as [String: Any]
            }
        case "debug.error":
            owner.note(first as? String ?? "?", for: id)
            return nil

        // MARK: its button
        case "action.popup": return nil
        case "action.open":
            owner.open(id)
            return nil

        // MARK: scripts
        case "scripting.file":
            return try scriptingFile(first as? String ?? "", arguments: args.dropFirst().first as? [Any] ?? [], in: Extensions.folder(for: id))
        case "userScripts.file":
            return try userScriptFile(first as? [String: Any] ?? [:], in: Extensions.folder(for: id))
        case "userScripts.list":
            return (try? JSONSerialization.jsonObject(with: Data(contentsOf: Extensions.folder(for: id).appendingPathComponent("_search/userscripts.json")))) ?? [Any]()
        case "userScripts.save":
            let folder = Extensions.folder(for: id).appendingPathComponent("_search", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: first as? [[String: Any]] ?? []).write(to: folder.appendingPathComponent("userscripts.json"), options: .atomic)
            return nil
        case "userScripts.world", "userScripts.worlds":
            let url = Extensions.folder(for: id).appendingPathComponent("_search/worlds.json")
            var worlds = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [[String: Any]] ?? []
            if api == "userScripts.worlds" { return worlds }
            let props = first as? [String: Any] ?? [:]
            let world = props["worldId"] as? String ?? ""
            worlds.removeAll { ($0["worldId"] as? String ?? "") == world }
            if props["reset"] as? Bool != true { worlds.append(props) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: worlds).write(to: url, options: .atomic)
            return nil

        // MARK: permissions the app grants itself
        case "permissions.granted":
            return Store.settings.stringArray(forKey: "extensions.granted.\(id)") ?? [String]()
        case "permissions.request":
            let wanted = (first as? [String]) ?? []
            let manifest = context.webExtension.manifest
            let named = Set(((manifest["permissions"] as? [Any] ?? []) + (manifest["optional_permissions"] as? [Any] ?? [])).compactMap { $0 as? String })
            guard wanted.allSatisfy(named.contains) else { throw Unsupported(what: "Only permissions specified in the manifest may be requested.") }
            let silent: Set<String> = ["tabGroups", "sidePanel", "offscreen", "idle", "power", "fontSettings", "search",
                                       "system.cpu", "system.memory", "system.display", "favicon"]
            guard wanted.allSatisfy(silent.contains) ? true : await owner.ask(wanted.joined(separator: ", "), context: context) else { return false }
            let had = Store.settings.stringArray(forKey: "extensions.granted.\(id)") ?? []
            Store.settings.set(Array(Set(had + wanted)).sorted(), forKey: "extensions.granted.\(id)")
            return true
        case "permissions.afterClick":
            let found = context.webExtension
            let wanted = ((first as? [String]) ?? []).map { WKWebExtension.Permission(rawValue: $0) }
            let origins = ((args.dropFirst().first as? [String]) ?? []).compactMap { try? WKWebExtension.MatchPattern(string: $0) }
                .filter { !Extensions.reachesExtensions($0) }
            let named = found.requestedPermissions.union(found.optionalPermissions)
            let places = found.allRequestedMatchPatterns.union(found.optionalPermissionMatchPatterns)
            guard wanted.allSatisfy(named.contains), origins.allSatisfy({ origin in places.contains { $0.matches(origin, options: .ignorePaths) } })
            else { throw Unsupported(what: "Only permissions specified in the manifest may be requested.") }
            let words = (wanted.map(\.rawValue) + origins.map(\.string)).sorted().joined(separator: ", ")
            guard await owner.ask(words, context: context) else { return false }
            for permission in wanted { context.setPermissionStatus(.grantedExplicitly, for: permission) }
            for pattern in origins { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
            Extensions.fence(context)
            return true
        case "permissions.removeWebsites": return true
        case "permissions.remove":
            let gone = Set((first as? [String]) ?? [])
            let had = Store.settings.stringArray(forKey: "extensions.granted.\(id)") ?? []
            Store.settings.set(had.filter { !gone.contains($0) }, forKey: "extensions.granted.\(id)")
            return true

        // MARK: tabs
        case "tabs.describe":
            return (first as? [Any] ?? []).map { place -> Any in
                guard let tab = located(place, owner: owner) else { return NSNull() }
                if tab.address?.scheme == Extensions.scheme, tab.address?.host() != id { return ["url": "", "title": ""] }
                return ["url": tab.address?.absoluteString ?? "", "title": tab.title]
            }
        case "tabs.private":
            guard let places = first as? [Any] else { return false }
            return places.map { place -> Any in located(place, owner: owner).map { $0.isPrivate } ?? NSNull() }
        case "tabs.activate":
            guard let tab = located(first, owner: owner) else { throw Unsupported(what: "No tab there") }
            browser.select(tab)
            return nil
        case "tabs.move", "tabs.discard": return nil
        case "search.query":
            let spec = first as? [String: Any] ?? [:]
            guard let url = Engine.url(for: spec["text"] as? String ?? "", template: Prefs.shared.searchTemplate) else { return nil }
            if ["NEW_TAB", "NEW_WINDOW"].contains(spec["disposition"] as? String ?? "") { browser.openPage(url) } else { browser.active?.go(to: url) }
            return nil

        // MARK: tab groups
        case "tabs.groups":
            let all = listed(owner)
            return (first as? [Any] ?? []).map { place -> Int in
                guard let tab = located(place, owner: owner) else { return -1 }
                return all.first { $0.1.tabs.contains(tab.id) }?.0 ?? -1
            }
        case "tabGroups.query":
            let spec = first as? [String: Any] ?? [:]
            return listed(owner).filter { _, group in
                (spec["title"] as? String).map { $0 == group.title } ?? true
                    && (spec["collapsed"] as? Bool).map { $0 == group.collapsed } ?? true
                    && (spec["color"] as? String).map { $0 == group.color } ?? true
            }.map(chromeGroup)
        case "tabGroups.get":
            guard let number = first as? Int, let found = listed(owner).first(where: { $0.0 == number }) else { throw Unsupported(what: "No group with id: \(first ?? "none").") }
            return chromeGroup(found.0, found.1)
        case "tabGroups.update":
            guard let number = first as? Int, groups[number] != nil else { throw Unsupported(what: "No group with id: \(first ?? "none").") }
            let props = args.dropFirst().first as? [String: Any] ?? [:]
            if let title = props["title"] as? String { groups[number]?.title = title }
            if let color = props["color"] as? String { groups[number]?.color = color }
            if let collapsed = props["collapsed"] as? Bool { groups[number]?.collapsed = collapsed }
            return chromeGroup(number, groups[number]!)
        case "tabGroups.move":
            guard let number = first as? Int, let group = groups[number] else { throw Unsupported(what: "No group there") }
            return chromeGroup(number, group)
        case "tabs.group":
            let tabs = (first as? [Any] ?? []).compactMap { located($0, owner: owner) }
            guard !tabs.isEmpty else { throw Unsupported(what: "No tabs to group") }
            var number = args.dropFirst().first as? Int ?? -1
            if number == -1 {
                groupCount += 1
                number = groupCount
                groups[number] = Group()
            }
            guard groups[number] != nil else { throw Unsupported(what: "No group with id: \(number).") }
            let ids = Set(tabs.map(\.id))
            for other in groups.keys where other != number { groups[other]?.tabs.subtract(ids) }
            groups[number]?.tabs.formUnion(ids)
            _ = listed(owner)
            return number
        case "tabs.ungroup":
            let ids = Set((first as? [Any] ?? []).compactMap { located($0, owner: owner)?.id })
            for number in groups.keys { groups[number]?.tabs.subtract(ids) }
            _ = listed(owner)
            return nil

        // MARK: the rest
        case "idle.queryState": return "active"
        case "idle.getAutoLockDelay": return 0
        case "power.requestKeepAwake": UIApplication.shared.isIdleTimerDisabled = true; return nil
        case "power.releaseKeepAwake": UIApplication.shared.isIdleTimerDisabled = false; return nil
        case "power.reportActivity": return nil
        case "system.cpu.getInfo":
            return ["numOfProcessors": ProcessInfo.processInfo.processorCount, "archName": "arm64", "modelName": "Apple", "features": [String](), "processors": [Any](), "temperatures": [Any]()] as [String: Any]
        case "system.memory.getInfo":
            return ["capacity": ProcessInfo.processInfo.physicalMemory, "availableCapacity": ProcessInfo.processInfo.physicalMemory / 2] as [String: Any]
        case "system.storage.getInfo": return [Any]()
        case "system.display.getInfo":
            let bounds = UIScreen.main.bounds
            let box: [String: Any] = ["left": 0, "top": 0, "width": bounds.width, "height": bounds.height]
            return [["id": "1", "name": "iPhone", "isPrimary": true, "isInternal": true, "isEnabled": true, "bounds": box, "workArea": box, "dpiX": 326, "dpiY": 326, "rotation": 0] as [String: Any]]

        // MARK: identity
        case "identity.launchWebAuthFlow":
            let spec = first as? [String: Any] ?? [:]
            guard let url = (spec["url"] as? String).flatMap(URL.init(string:)) else { throw Unsupported(what: "No authorization url") }
            if spec["interactive"] as? Bool != true {
                let wait = (spec["timeoutMsForNonInteractive"] as? NSNumber).map { $0.doubleValue / 1000 }
                return try await ExtensionAuth.quietly(url, extension: id, abortOnLoad: spec["abortOnLoadForNonInteractive"] as? Bool ?? true, timeout: wait).absoluteString
            }
            return try await ExtensionAuth.run(url, extension: id, browser: browser).absoluteString
        case "identity.getProfileUserInfo": return ["email": "", "id": ""]
        case "identity.removeCachedAuthToken", "identity.clearAllCachedAuthTokens": return nil

        default:
            throw Unsupported(what: "\(api) isn't available on iOS")
        }
    }
}
