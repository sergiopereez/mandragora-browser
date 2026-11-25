import CryptoKit
import SwiftUI
import WebKit

// An extension's own pages that aren't tabs: its side panel, here a sheet
// over the lower half of the page with the page still yours above it; the
// page with a DOM its background asks for (offscreen); and the sign-in a
// provider runs (identity.launchWebAuthFlow).

// MARK: - the side panel

@available(iOS 18.4, *)
@MainActor
final class ExtensionPanel: NSObject, ObservableObject {
    static let shared = ExtensionPanel()

    /// The extension whose panel is up or put away, for the button that
    /// brings it back.
    @Published private(set) var current: String?
    @Published private(set) var shown = false

    private var controllers: [String: PanelController] = [:]
    /// The last used first; a few are kept so a panel comes back as it was.
    private var order: [String] = []

    func show(_ url: URL, of context: WKWebExtensionContext) {
        let id = context.uniqueIdentifier
        let panel: PanelController
        if let kept = controllers[id], kept.context === context {
            panel = kept
            // Claude's names its tab in the address: another tab, another.
            if panel.web.url?.absoluteString != url.absoluteString, panel.asked != url { panel.load(url) }
        } else {
            guard let configuration = context.webViewConfiguration else { return }
            panel = PanelController(context: context, configuration: configuration)
            controllers[id] = panel
            panel.load(url)
        }
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
        for old in order.dropFirst(3) { drop(old) }
        current = id
        present(panel)
    }

    /// Brought back as it was left.
    func restore() {
        guard let current, let panel = controllers[current] else { return }
        present(panel)
    }

    /// Put away, its page still there and running.
    func hide(then next: (() -> Void)? = nil) {
        guard let current, let panel = controllers[current], panel.presentingViewController != nil else { next?(); return }
        panel.dismiss(animated: true) { next?() }
        shown = false
    }

    /// Made small, so what it opened can be seen.
    func lower() {
        guard let current, let sheet = controllers[current]?.sheetPresentationController, shown else { return }
        sheet.animateChanges { sheet.selectedDetentIdentifier = PanelController.small }
    }

    func close(_ id: String) {
        drop(id)
        if current == id { current = nil }
    }

    func address(of id: String) -> URL? { controllers[id]?.web.url }

    private func drop(_ id: String) {
        guard let panel = controllers.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        if panel.presentingViewController != nil { panel.dismiss(animated: true); shown = false }
        panel.web.stopLoading()
    }

    private func present(_ panel: PanelController, tries: Int = 0) {
        guard panel.presentingViewController == nil else {
            panel.sheetPresentationController?.animateChanges { panel.sheetPresentationController?.selectedDetentIdentifier = .medium }
            return
        }
        // A sheet on its way out can't present anything: once it is gone.
        guard let top = Extensions.topController, !top.isBeingDismissed, !top.isBeingPresented, !panel.isBeingDismissed else {
            guard tries < 12 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.present(panel, tries: tries + 1) }
            return
        }
        if let other = top as? PanelController {
            other.dismiss(animated: false) { [weak self] in self?.present(panel) }
            return
        }
        panel.modalPresentationStyle = .pageSheet
        if let sheet = panel.sheetPresentationController {
            sheet.detents = [
                .custom(identifier: PanelController.small) { _ in 92 },
                .medium(), .large(),
            ]
            sheet.selectedDetentIdentifier = .medium
            // The page above it stays yours to scroll and tap.
            sheet.largestUndimmedDetentIdentifier = .medium
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
            sheet.delegate = panel
        }
        panel.gone = { [weak self] in self?.shown = false }
        panel.closed = { [weak self] in self?.close(panel.context.uniqueIdentifier) }
        top.present(panel, animated: true)
        shown = panel.presentingViewController != nil
    }
}

@available(iOS 18.4, *)
@MainActor
final class PanelController: UIViewController, WKNavigationDelegate, WKUIDelegate, UISheetPresentationControllerDelegate {
    static let small = UISheetPresentationController.Detent.Identifier("small")

    let context: WKWebExtensionContext
    let web: WKWebView
    private let cookies: PanelCookies
    var asked: URL?
    var gone: (() -> Void)?
    var closed: (() -> Void)?
    private var reloads = 0

    init(context: WKWebExtensionContext, configuration: WKWebViewConfiguration) {
        self.context = context
        // It goes on working while it is put away: an agent's loop runs here.
        configuration.preferences.inactiveSchedulingPolicy = .none
        configuration.allowsInlineMediaPlayback = true
        // A site it shows in a frame is signed in as your tabs are.
        cookies = PanelCookies.of(context)
        // WebKit ties an extension's pages to its background's view, and so
        // to its store; it raises if the two differ. Untied where it can be.
        let untie = NSSelectorFromString("_setRelatedWebView:")
        if cookies.needed, configuration.responds(to: untie) {
            configuration.perform(untie, with: nil)
            configuration.websiteDataStore = cookies.store
        }
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 500), configuration: configuration)
        super.init(nibName: nil, bundle: nil)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.isInspectable = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func load(_ url: URL) {
        asked = url
        web.load(URLRequest(url: url))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let icon = UIImageView(image: context.webExtension.icon(for: CGSize(width: 22, height: 22)))
        icon.contentMode = .scaleAspectFit
        let title = UILabel()
        title.text = context.webExtension.displayShortName ?? context.webExtension.displayName
        title.font = .preferredFont(forTextStyle: .headline)
        let close = UIButton(type: .system, primaryAction: UIAction(image: UIImage(systemName: "xmark.circle.fill")) { [weak self] _ in
            self?.dismiss(animated: true) { self?.closed?() }
        })
        close.tintColor = .tertiaryLabel
        close.accessibilityLabel = String(localized: "Close")
        let bar = UIStackView(arrangedSubviews: [icon, title, UIView(), close])
        bar.spacing = 8
        bar.alignment = .center
        for piece in [bar, web] as [UIView] {
            piece.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(piece)
        }
        // Down to the sheet's own foot when there is no keyboard.
        view.keyboardLayoutGuide.usesBottomSafeArea = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 22), icon.heightAnchor.constraint(equalToConstant: 22),
            bar.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            bar.heightAnchor.constraint(equalToConstant: 34),
            web.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        gone?()
    }

    // The panel stays on the extension's own pages; anything else it goes to
    // is a page for a tab. Its frames go where they like.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        guard action.targetFrame?.isMainFrame != false else {
            // A site the extension names, in a frame of its own page (Claude's
            // panel is claude.ai itself): its sign-in first, then the frame.
            if let url, action.sourceFrame.isMainFrame, cookies.names(url) {
                Task {
                    await cookies.lend(to: url)
                    decisionHandler(.allow)
                }
                return
            }
            return decisionHandler(.allow)
        }
        if url?.scheme == context.baseURL.scheme, url?.host() == context.baseURL.host() { return decisionHandler(.allow) }
        decisionHandler(.cancel)
        if let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            ExtensionPanel.shared.lower()
            Extensions.shared.browser?.openPage(url)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            ExtensionPanel.shared.lower()
            Extensions.shared.browser?.openPage(url)
        }
        return nil
    }

    func webViewDidClose(_ webView: WKWebView) {
        dismiss(animated: true) { [weak self] in self?.closed?() }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard reloads < 2, let asked else { return }
        reloads += 1
        webView.load(URLRequest(url: asked))
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }
}

/// The sign-in of a site an extension shows in a frame of its panel.
///
/// Chrome counts a site the extension may reach as its own: a frame of it in
/// the panel is signed in as your tabs are. WebKit counts it as another
/// site's, and sends it none of the cookies a site keeps to its own pages
/// (SameSite=Lax, which is what a sign-in is): Claude's panel, claude.ai in a
/// frame, was signed out. So the panel has a store of its own, where that
/// site's cookies are put without that mark.
///
/// Kept narrow. Nothing changes in the store your tabs use. Each extension
/// has its own, nothing but its panel is loaded with it, and only sites its
/// manifest names one by one get in, never "every site"; only in a frame its
/// own page asks for; and it goes when the extension does.
@available(iOS 18.4, *)
@MainActor
final class PanelCookies: NSObject, WKHTTPCookieStoreObserver {
    private static var made: [String: PanelCookies] = [:]

    static func of(_ context: WKWebExtensionContext) -> PanelCookies {
        let id = context.uniqueIdentifier
        if let kept = made[id] {
            kept.read(context.webExtension.manifest)
            return kept
        }
        let fresh = PanelCookies(id)
        fresh.read(context.webExtension.manifest)
        made[id] = fresh
        return fresh
    }

    static func identifier(_ id: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("search.panel.\(id)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// The extension is gone, and what its panel kept with it.
    static func forget(_ id: String) {
        made.removeValue(forKey: id)?.end()
        let gone = identifier(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { WKWebsiteDataStore.remove(forIdentifier: gone) { _ in } }
    }

    /// Cookies and website data cleared: these go as well.
    static func clear() {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        for kept in made.values {
            kept.given = [:]
            kept.store.removeData(ofTypes: types, modifiedSince: .distantPast) {}
        }
        let open = Set(made.keys.map(identifier))
        WKWebsiteDataStore.fetchAllDataStoreIdentifiers { all in
            for id in all where !open.contains(id) { WKWebsiteDataStore.remove(forIdentifier: id) { _ in } }
        }
    }

    let store: WKWebsiteDataStore
    private var sites: [String] = []
    private var lent: Set<String> = []
    private var working = false
    private var again = false

    private init(_ id: String) {
        store = WKWebsiteDataStore(forIdentifier: Self.identifier(id))
        super.init()
        store.httpCookieStore.add(self)
        WKWebsiteDataStore.default().httpCookieStore.add(self)
    }

    private func end() {
        store.httpCookieStore.remove(self)
        WKWebsiteDataStore.default().httpCookieStore.remove(self)
    }

    /// The sites its manifest names: those it talks with, runs in or asks
    /// for by name.
    private func read(_ manifest: [String: Any]) {
        var patterns = (manifest["externally_connectable"] as? [String: Any])?["matches"] as? [String] ?? []
        patterns += manifest["host_permissions"] as? [String] ?? []
        for entry in manifest["content_scripts"] as? [[String: Any]] ?? [] { patterns += entry["matches"] as? [String] ?? [] }
        sites = Array(Set(patterns.compactMap { pattern -> String? in
            guard let range = pattern.range(of: "://") else { return nil }
            var host = String(pattern[range.upperBound...].prefix { $0 != "/" }).lowercased()
            if host.hasPrefix("*.") { host.removeFirst(2) }
            if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
            // Named outright, and more than a top-level name.
            guard !host.isEmpty, !host.contains("*"), host.contains(".") || host == "localhost" else { return nil }
            return host
        }))
    }

    /// Only an extension that names a site at all has anything to lend.
    var needed: Bool { !sites.isEmpty }

    func names(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased(), url.scheme == "https" || host == "localhost" else { return false }
        return sites.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static func covers(_ cookie: HTTPCookie, _ host: String) -> Bool {
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host == domain || (cookie.domain.hasPrefix(".") && host.hasSuffix("." + domain))
    }

    /// The same cookie for the panel: without the mark that keeps it to its
    /// own site's pages, and everything else as it was.
    private static func plain(_ cookie: HTTPCookie) -> HTTPCookie? {
        guard var properties = cookie.properties else { return nil }
        properties[.sameSitePolicy] = nil
        return HTTPCookie(properties: properties)
    }

    func lend(to url: URL) async {
        guard let host = url.host()?.lowercased() else { return }
        lent.insert(host)
        await settle()
    }

    /// Your tabs' cookies for the sites lent, put in the panel when they are
    /// new or have changed there, and taken away when they are gone from
    /// there. Those the site sets in the panel itself are left as they are,
    /// and never reach your tabs.
    private func settle() async {
        guard !lent.isEmpty else { return }
        if working { again = true; return }
        working = true
        defer { working = false }
        repeat {
            again = false
            let jar = store.httpCookieStore
            let here = await jar.allCookies(), there = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            var seen: Set<String> = []
            for cookie in there where !ExtensionFetch.partitioned(cookie) && lent.contains(where: { Self.covers(cookie, $0) }) {
                let key = Self.key(cookie)
                seen.insert(key)
                let mine = here.first { Self.key($0) == key }
                guard given[key] != cookie.value || mine == nil || mine?.sameSitePolicy != nil else { continue }
                given[key] = cookie.value
                if let plain = Self.plain(cookie) { await jar.setCookie(plain) }
            }
            for key in given.keys where !seen.contains(key) {
                given[key] = nil
                if let mine = here.first(where: { Self.key($0) == key }) { await jar.deleteCookie(mine) }
            }
        } while again
    }

    private static func key(_ cookie: HTTPCookie) -> String { "\(cookie.name)\n\(cookie.domain)\n\(cookie.path)" }
    /// What was given, and as it was: only a change in the tabs' store is
    /// carried over.
    private var given: [String: String] = [:]

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in await self.settle() }
    }
}

/// The way back to a panel that was put away.
@available(iOS 18.4, *)
struct PanelButton: View {
    @ObservedObject private var panel = ExtensionPanel.shared

    var body: some View {
        if let id = panel.current, !panel.shown {
            Button { panel.restore() } label: {
                Group {
                    if let icon = Extensions.shared.icon(of: id) {
                        Image(uiImage: icon).resizable().scaledToFit()
                    } else {
                        Image(systemName: "sidebar.right")
                    }
                }
                .frame(width: 24, height: 24)
                .frame(width: 44, height: 44)
                .glass(Circle(), interactive: true, else: Palette.ground)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Close panel", role: .destructive) { panel.close(id) }
            }
            .transition(.scale.combined(with: .opacity))
        }
    }
}

// MARK: - offscreen

/// A DOM owned by an extension, never a tab.
@available(iOS 18.4, *)
@MainActor
final class ExtensionOffscreen: NSObject, WKNavigationDelegate, WKWebExtensionTab {
    private static var documents: [String: ExtensionOffscreen] = [:]

    static func create(_ path: String, for context: WKWebExtensionContext) async throws {
        let id = context.uniqueIdentifier
        guard documents[id] == nil else { throw ExtensionShims.Unsupported(what: "Only a single offscreen document may be created.") }
        guard let url = ExtensionShims.page(path, in: context), let configuration = context.webViewConfiguration
        else { throw ExtensionShims.Unsupported(what: "The offscreen document must belong to this extension.") }
        configuration.preferences.inactiveSchedulingPolicy = .none
        let document = ExtensionOffscreen(context: context, url: url, configuration: configuration)
        documents[id] = document
        // WebKit needs a tab to know the page by; only its owner sees it.
        context.didOpenTab(document)
        try await document.load()
    }

    static func close(for id: String) { documents[id]?.end(ExtensionShims.Unsupported(what: "The offscreen document was closed.")) }
    static func hasDocument(for id: String) -> Bool { documents[id] != nil }
    static func url(for id: String) -> URL? { documents[id]?.web.url }

    private let context: WKWebExtensionContext
    private let url: URL
    private let web: WKWebView
    private var loading: CheckedContinuation<Void, Error>?

    private init(context: WKWebExtensionContext, url: URL, configuration: WKWebViewConfiguration) {
        self.context = context
        self.url = url
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        super.init()
        web.navigationDelegate = self
    }

    private func load() async throws {
        try await withCheckedThrowingContinuation { continuation in
            loading = continuation
            web.load(URLRequest(url: url))
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self, self.loading != nil else { return }
                self.end(ExtensionShims.Unsupported(what: "The offscreen document did not finish loading."))
            }
        }
    }

    private func end(_ error: Error) {
        if Self.documents[context.uniqueIdentifier] === self { Self.documents[context.uniqueIdentifier] = nil }
        context.didCloseTab(self, windowIsClosing: false)
        web.navigationDelegate = nil
        web.stopLoading()
        loading?.resume(throwing: error)
        loading = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading?.resume()
        loading = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if loading != nil { end(error) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard action.targetFrame?.isMainFrame != false else { return decisionHandler(.allow) }
        let to = action.request.url
        decisionHandler(to?.scheme == url.scheme && to?.host() == url.host() ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        end(ExtensionShims.Unsupported(what: "The offscreen document's web process exited."))
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { nil }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { NSNotFound }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { web }
    func url(for context: WKWebExtensionContext) -> URL? { web.url }
    func isSelected(for context: WKWebExtensionContext) -> Bool { false }
}

// MARK: - signing in

/// chrome.identity.launchWebAuthFlow: a tab for the provider's sign-in, and
/// the moment it heads for https://<id>.chromiumapp.org/, that address is
/// the answer and the tab goes. Nothing is ever loaded from there.
@available(iOS 18.4, *)
@MainActor
enum ExtensionAuth {
    private static var waiting: [String: (tab: Tab.ID, finish: (Result<URL, Error>) -> Void)] = [:]
    private static var quiet: [String: Quiet] = [:]

    private static func failure(_ why: String) -> Error {
        NSError(domain: "Search", code: 1, userInfo: [NSLocalizedDescriptionKey: why])
    }

    static func run(_ url: URL, extension id: String, browser: Browser) async throws -> URL {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw failure("Authorization page could not be loaded.") }
        return try await withCheckedThrowingContinuation { continuation in
            waiting[id]?.finish(.failure(failure("The user did not approve access.")))
            ExtensionPanel.shared.lower()
            browser.openPage(url)
            guard let tab = browser.active else {
                continuation.resume(throwing: failure("Authorization page could not be loaded."))
                return
            }
            waiting[id] = (tab.id, { continuation.resume(with: $0) })
            let started = Date()
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
                MainActor.assumeIsolated {
                    guard let entry = waiting[id], entry.tab == tab.id else { timer.invalidate(); return }
                    // Closing the tab is saying no; so is ten minutes.
                    guard !browser.tabs.contains(where: { $0.id == entry.tab }) || Date().timeIntervalSince(started) > 600 else { return }
                    timer.invalidate()
                    waiting[id] = nil
                    entry.finish(.failure(failure("The user did not approve access.")))
                }
            }
        }
    }

    /// Asked about every navigation in a tab: true when it was the answer.
    static func intercept(_ url: URL, browser: Browser, from web: WKWebView) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased(), host.hasSuffix(".chromiumapp.org") else { return false }
        let id = String(host.dropLast(".chromiumapp.org".count))
        guard let entry = waiting[id], let tab = browser.tabs.first(where: { $0.web === web }), tab.id == entry.tab else { return false }
        waiting[id] = nil
        entry.finish(.success(url))
        browser.close(tab)
        ExtensionPanel.shared.restore()
        return true
    }

    /// Out of sight: it comes straight back or fails.
    static func quietly(_ url: URL, extension id: String, abortOnLoad: Bool, timeout: TimeInterval?) async throws -> URL {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw failure("Authorization page could not be loaded.") }
        return try await withCheckedThrowingContinuation { continuation in
            quiet[id]?.end(.failure(failure("User interaction required.")))
            let flow = Quiet(id: id, abortOnLoad: abortOnLoad) { result in
                quiet[id] = nil
                continuation.resume(with: result)
            }
            quiet[id] = flow
            flow.start(url, limit: min(max(timeout ?? 60, 0.5), 60))
        }
    }

    @MainActor
    final class Quiet: NSObject, WKNavigationDelegate {
        let id: String
        let abortOnLoad: Bool
        private var finish: ((Result<URL, Error>) -> Void)?
        private var web: WKWebView?

        init(id: String, abortOnLoad: Bool, finish: @escaping (Result<URL, Error>) -> Void) {
            self.id = id.lowercased()
            self.abortOnLoad = abortOnLoad
            self.finish = finish
        }

        func start(_ url: URL, limit: TimeInterval) {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .default()
            config.applicationNameForUserAgent = Web.userAgentTail
            config.mediaTypesRequiringUserActionForPlayback = .all
            let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 700), configuration: config)
            web.navigationDelegate = self
            self.web = web
            DispatchQueue.main.asyncAfter(deadline: .now() + limit) { [weak self] in
                self?.end(.failure(ExtensionAuth.failure("User interaction required.")))
            }
            web.load(URLRequest(url: url))
        }

        func end(_ result: Result<URL, Error>) {
            guard let finish else { return }
            self.finish = nil
            web?.navigationDelegate = nil
            web?.stopLoading()
            web = nil
            finish(result)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard action.targetFrame?.isMainFrame != false else { return decisionHandler(.allow) }
            guard let url = action.request.url, let host = url.host()?.lowercased() else { return decisionHandler(.cancel) }
            if host == "chromiumapp.org" || host.hasSuffix(".chromiumapp.org") {
                decisionHandler(.cancel)
                end(host == id + ".chromiumapp.org" && url.scheme == "https"
                    ? .success(url) : .failure(ExtensionAuth.failure("Authorization page could not be loaded.")))
                return
            }
            decisionHandler(["http", "https"].contains(url.scheme?.lowercased() ?? "") ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if abortOnLoad { end(.failure(ExtensionAuth.failure("User interaction required."))) }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let error = error as NSError
            if error.code == NSURLErrorCancelled || error.code == 102 { return }
            end(.failure(ExtensionAuth.failure("Authorization page could not be loaded.")))
        }
    }
}
