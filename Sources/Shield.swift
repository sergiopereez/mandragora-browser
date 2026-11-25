import WebKit

// The ad blocker, the Mac's list as it is, Reddit's promoted posts and
// YouTube's ads included (YouTubeAds.swift). No counter, no shield icon going
// green — it is compiled once at launch and then it is simply true that the
// page is lighter. One switch in Settings, and off per site from the pill.
//
// A content rule list is enforced inside WebKit's networking, before a request
// is made and before a stylesheet is applied, so this costs nothing at run time
// in the way a JavaScript blocker does.

@MainActor
final class Shield: ObservableObject {
    static let shared = Shield()

    private(set) var list: WKContentRuleList?
    private var waiting: [WKUserContentController] = []

    /// Set the one time compiling the list didn't work. The toggle in
    /// Settings can say "on" all it wants; nothing is actually blocked until
    /// this is nil, so it is the one thing worth telling a person about
    /// rather than failing the quiet way a missing ad is quiet.
    @Published private(set) var trouble: String?

    /// On unless somebody said otherwise. Every tab's controller is told when
    /// this changes, so it takes effect on the next request rather than the
    /// next launch.
    var enabled = Store.settings.object(forKey: "shield.enabled") as? Bool ?? true {
        didSet { Store.settings.set(enabled, forKey: "shield.enabled") }
    }

    /// Sites it is off for — the ones it broke. A checkout that never
    /// finishes, a video that never starts: switching off here, for this site,
    /// beats switching off everywhere and forgetting to switch back.
    private(set) var paused: Set<String> = Set(
        Store.settings.stringArray(forKey: "shield.paused") ?? []
    )

    func isPaused(on host: String?) -> Bool {
        guard let host else { return false }
        return paused.contains(host)
    }

    func pause(_ host: String, _ off: Bool) {
        if off { paused.insert(host) } else { paused.remove(host) }
        Store.settings.set(Array(paused).sorted(), forKey: "shield.paused")
    }

    /// Before each page: the list goes on or off for the site this tab is
    /// heading to. A rule list is enforced from the moment it is added, so
    /// doing this at the navigation is what makes "off for this site" true
    /// for the whole page rather than for the second half of it.
    func tune(_ controller: WKUserContentController, for host: String?) {
        let on = enabled && !isPaused(on: host)
        // The user scripts every page gets (Web.baseScripts) and, with the
        // blocker on, YouTube's.
        let site = host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
        Self.install(Web.baseScripts() + (on ? YouTubeAds.scripts(for: site) : []), in: controller)
        guard let list else { return }
        controller.remove(list)
        if on { controller.add(list) }
    }

    /// Third parties whose only job is to watch or to sell. First-party
    /// requests are untouched: a site's own scripts are the site.
    private static let unwanted = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "googletagservices.com", "google-analytics.com", "googletagmanager.com",
        "adservice.google.com", "amazon-adsystem.com", "adnxs.com", "adsrvr.org",
        "criteo.com", "criteo.net", "taboola.com", "outbrain.com",
        "rubiconproject.com", "pubmatic.com", "openx.net", "casalemedia.com",
        "smartadserver.com", "sharethrough.com", "indexww.com", "bidswitch.net",
        "33across.com", "teads.tv", "moatads.com", "adroll.com",
        "scorecardresearch.com", "quantserve.com", "chartbeat.com",
        "hotjar.com", "mouseflow.com", "fullstory.com", "clarity.ms",
        "mixpanel.com", "amplitude.com", "segment.com", "segment.io",
        "branch.io", "appsflyer.com", "adjust.com", "analytics.tiktok.com",
        "connect.facebook.net", "ads-twitter.com", "analytics.twitter.com",
    ]

    /// The few slots that are reliably an advertisement and nothing else. Kept
    /// deliberately short — a generous cosmetic list is how a blocker starts
    /// eating the page it was meant to clean.
    ///
    /// The second half are the boxes a site keeps open for the ad while it
    /// loads: with the ad blocked they stay, empty, a banner's height of
    /// nothing (#159). Each is a whole class name from EasyList's generic
    /// hiding list, matched as a whole word: an element whose class is
    /// `ad-slot` goes, one whose class merely contains "ad" stays.
    private static let slots = [
        ".adsbygoogle", "ins.adsbygoogle", "[id^=\"google_ads_\"]",
        "[id^=\"div-gpt-ad\"]", "[id^=\"taboola-\"]", "#taboola-below-article",
        "iframe[src*=\"doubleclick.net\"]", "iframe[src*=\"googlesyndication\"]",
        "iframe[src*=\"amazon-adsystem\"]",
        ".ad-slot", ".ad-slot-container", ".top-banner-ad-container",
        ".ad-leaderboard", ".ad-billboard", ".ad-giga", ".ad-mpu", ".ad-mrec",
        ".ad-unit", ".adunit", ".adslot", ".dfp-ad", ".gpt-ad", ".w_ad",
    ]

    /// Slots with names too plain, or too much a site's own, to hide
    /// everywhere — AS and El País call theirs just `.ad` — hidden only on
    /// the sites EasyList's own site rules hide them on.
    private static let slotsBySite: [(sites: [String], selector: String)] = [
        (["*as.com", "*elpais.com"], ".ad"),
        (["*theguardian.com"], ".top-fronts-banner-ad-container"),
        (["*independent.co.uk", "*the-independent.com"], "#billboard-wrapper"),
        (["*cnn.com"], ".ad-slot-header__wrapper"),
    ]

    /// Reddit's own promoted posts: custom elements the page puts straight
    /// in its light DOM (the feed, a post's comments, the sidebar), so a
    /// plain hiding rule reaches them. Only reddit.com; a normal post is a
    /// `shreddit-post`, never one of these. The Mac's list.
    private static let reddit = [
        "shreddit-ad-post", "shreddit-comments-page-ad", "shreddit-sidebar-ad",
        "shreddit-dynamic-ad-link", "comment-tree-ad", ".promotedlink",
    ]

    static func networkFilter(for domain: String) -> String {
        let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
        // WebKit's canonical HTTP URLs end the host with a port or a slash.
        return "^https?://([^/]+\\.)?\(escaped)[:/]"
    }

    func compile() {
        guard list == nil else { return }
        trouble = nil
        var rules: [[String: Any]] = Shield.unwanted.map { domain in
            [
                "trigger": [
                    "url-filter": Shield.networkFilter(for: domain),
                    "load-type": ["third-party"],
                ],
                "action": ["type": "block"],
            ]
        }
        rules.append([
            "trigger": ["url-filter": ".*"],
            "action": ["type": "css-display-none", "selector": Shield.slots.joined(separator: ", ")],
        ])
        // YouTube's ad reports and ad paths (see YouTubeAds.swift).
        rules += YouTubeAds.rules
        rules += Shield.slotsBySite.map { entry in
            [
                "trigger": ["url-filter": ".*", "if-domain": entry.sites],
                "action": ["type": "css-display-none", "selector": entry.selector],
            ]
        }
        rules.append([
            "trigger": ["url-filter": ".*", "if-domain": ["*reddit.com"]],
            "action": ["type": "css-display-none", "selector": Shield.reddit.joined(separator: ", ")],
        ])

        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8)
        else {
            trouble = "Couldn't build the block list"
            return
        }

        guard let store = WKContentRuleListStore.default() else {
            trouble = "WebKit has nowhere to compile it"
            return
        }
        // A new name for a new list: the old compiled one is never taken
        // for this one.
        store.compileContentRuleList(
            forIdentifier: "office-shield-2",
            encodedContentRuleList: json
        ) { [weak self] compiled, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let compiled else {
                    self.trouble = error?.localizedDescription ?? "Compiling the block list failed"
                    return
                }
                self.list = compiled
                // Tabs that opened while this was still compiling get it now.
                if self.enabled { self.waiting.forEach { $0.add(compiled) } }
                self.waiting = []
            }
        }
    }

    /// Every tab asks for it; whoever asks before it is ready is remembered.
    func protect(_ controller: WKUserContentController) {
        if enabled { YouTubeAds.scripts(for: nil).forEach(controller.addUserScript) }
        if let list {
            if enabled { controller.add(list) }
        } else {
            waiting.append(controller)
        }
    }

    /// The same scripts as the document before's, the usual case, are left
    /// where they are (as on the Mac): taken out and put back on every link
    /// followed, they took the scripts WebKit keeps in the same controller
    /// for Chrome extensions with them, and no extension ever ran.
    static func install(_ scripts: [WKUserScript], in controller: WKUserContentController) {
        let ours = controller.userScripts.filter { script in scripts.contains { $0.source == script.source } }
        guard ours.map(\.source) != scripts.map(\.source) || controller.userScripts.count < scripts.count else { return }
        controller.removeAllUserScripts()
        scripts.forEach(controller.addUserScript)
    }

    /// Switched on or off for every page that is already open.
    func apply(to controllers: [WKUserContentController]) {
        guard let list else { return }
        for controller in controllers {
            Self.install(Web.baseScripts() + (enabled ? YouTubeAds.scripts(for: nil) : []), in: controller)
            controller.remove(list)
            if enabled { controller.add(list) }
        }
    }
}

// MARK: - cookie banners

// A cookie banner, answered "Reject all" without being asked: the button
// the site itself offers for it, pressed for you, and nothing else. Never
// "Accept", never a newsletter or any other pop-up: only a button whose
// whole label is a refusal, inside a banner that talks about cookies or
// consent. Where a site offers no way to refuse (pay or accept), it is
// left as it is.
//
// The big consent platforms first, by their own API or their own button
// (Didomi, Usercentrics, OneTrust, Cookiebot, Google's own…); then any
// other banner by what its button says, in Spanish, English, French,
// German, Italian, Portuguese and Catalan. In every frame, since some
// banners live in one, and for twenty seconds after the page starts, since
// most arrive late. In the page's own world, to reach those APIs, and
// leaving nothing behind on `window` that a page could notice.

@MainActor
enum Cookies {
    static var enabled: Bool {
        get { Store.settings.object(forKey: "cookies.reject") as? Bool ?? true }
        set { Store.settings.set(newValue, forKey: "cookies.reject") }
    }

    static func scripts() -> [WKUserScript] {
        guard enabled else { return [] }
        return [WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: .page)]
    }

    static let source = #"""
    (function () {
      'use strict';
      if (!document.documentElement) return;
      var started = Date.now(), done = false, pending = false, observer = null;
      var host = location.hostname || '';
      var framed = window !== window.top;
      var about = /cookie|consent|consentimiento|consentement|einwilligung|galetes/i;
      var refusal = new RegExp('^(' + [
        'rechazar', 'rechazarlas', 'rechazar todo', 'rechazar todas', 'rechazar todas las cookies',
        'rechazar cookies', 'rechazar las cookies', 'rechazar cookies opcionales', 'rechazar opcionales',
        'rechazar no necesarias', 'rechazar las no necesarias', 'rechazar cookies no necesarias',
        'no acepto', 'no aceptar', 'denegar', 'denegar todo', 'denegar todas',
        'continuar sin aceptar', 'seguir sin aceptar',
        's[oó]lo (las )?(cookies )?(necesarias|esenciales|imprescindibles|t[eé]cnicas)',
        'usar s[oó]lo (las )?cookies necesarias', 'permitir s[oó]lo (las )?(cookies )?necesarias',
        'reject', 'reject all', 'reject all cookies', 'reject cookies', 'reject optional cookies',
        'reject non-essential( cookies)?', 'decline', 'decline all', 'decline cookies',
        'decline optional cookies', 'deny', 'deny all', 'i do not accept', 'do not accept',
        'i decline', 'disagree', 'disagree and close', 'necessary only', 'necessary cookies only',
        'only necessary( cookies)?', 'only essential( cookies)?', 'only allow essential cookies',
        'allow necessary only', 'use necessary cookies only', 'essential only', 'essential cookies only',
        'continue without accepting', 'continue without agreeing',
        'refuse', 'refuse all', 'tout refuser', 'refuser', 'refuser tout', 'continuer sans accepter',
        'alle ablehnen', 'ablehnen', 'nur (notwendige|erforderliche|essenzielle)( cookies)?',
        'rifiuta', 'rifiuta tutto', 'rifiuta tutti', 'continua senza accettare',
        'rejeitar', 'rejeitar tudo', 'rejeitar todos', 'recusar', 'recusar tudo',
        'rebutjar', 'rebutjar-ho tot', 'rebutja-ho tot', 'nom[eé]s (les )?necess[aà]ries'
      ].join('|') + ')$', 'i');

      // Buttons that can only mean "no", by the platform that draws them.
      var known = [
        '#onetrust-reject-all-handler',
        '#CybotCookiebotDialogBodyButtonDecline',
        '#CybotCookiebotDialogBodyLevelButtonLevelOptinDeclineAll',
        '#didomi-notice-disagree-button',
        '.didomi-continue-without-agreeing',
        '.fc-cta-do-not-consent',
        '.cmplz-btn.cmplz-deny',
        '.cky-btn-reject',
        '.iubenda-cs-reject-btn',
        '.osano-cm-denyAll',
        '.cmpboxbtnno',
        '.cc-btn.cc-deny',
        '#cn-refuse-cookie',
        '#hs-eu-decline-button',
        '#shopify-pc__banner__btn-decline',
        '[data-cookiefirst-action="reject"]',
        '[data-testid="uc-deny-all-button"]',
        '#truste-consent-required'
      ];
      if (/(^|\.)google\.[a-z.]+$/.test(host)) known.push('#W0wltc');

      var candidates = 'button, [role="button"], input[type="button"], input[type="submit"], a:not([href]), a[href="#"], a[href^="#"], a[href^="javascript"]';

      function roots() {
        var list = [document];
        if (!document.body) return list;
        var top = document.body.children;
        for (var i = 0; i < top.length; i++) if (top[i].shadowRoot) list.push(top[i].shadowRoot);
        return list;
      }

      function visible(el) {
        if (el.disabled) return false;
        var r = el.getBoundingClientRect();
        if (r.width < 2 || r.height < 2) return false;
        var s = getComputedStyle(el);
        return s.visibility !== 'hidden' && s.display !== 'none' && parseFloat(s.opacity || '1') > 0.05;
      }

      function label(el) {
        var text = el.tagName === 'INPUT' ? (el.value || '') : (el.textContent || '');
        if (!text.trim()) text = el.getAttribute('aria-label') || '';
        if (text.length > 80) return '';
        return text.replace(/\s+/g, ' ').trim().toLowerCase().replace(/[\s.!»›→✕×]+$/, '').trim();
      }

      // The banner around a button: something fixed, a dialog, or named
      // for cookies, that talks about cookies or consent and isn't the
      // whole page. A frame of its own counts as one.
      function banner(el) {
        var node = el, depth = 0;
        while (node && depth < 16) {
          depth++;
          if (node.nodeType === 1) {
            if (node.tagName === 'BODY' || node.tagName === 'HTML') break;
            var name = (node.id || '') + ' ' + (typeof node.className === 'string' ? node.className : '');
            var role = node.getAttribute('role');
            var looks = /cookie|consent|gdpr|cmp|didomi|onetrust|cookiebot|usercentrics|privacy/i.test(name)
              || role === 'dialog' || role === 'alertdialog' || node.getAttribute('aria-modal') === 'true';
            if (!looks) {
              var position = getComputedStyle(node).position;
              looks = position === 'fixed' || position === 'sticky';
            }
            if (looks) {
              var text = node.textContent || '';
              if (text.length < 8000 && about.test(text)) return node;
            }
          }
          node = node.parentNode || node.host;
        }
        if ((framed || /^consent\./.test(host)) && document.body) {
          var all = document.body.textContent || '';
          if (all.length < 20000 && about.test(all)) return document.body;
        }
        return null;
      }

      function apis() {
        try {
          var D = window.Didomi;
          if (D && D.notice && D.notice.isVisible && D.notice.isVisible() && D.setUserDisagreeToAll) {
            D.setUserDisagreeToAll();
            return true;
          }
        } catch (e) {}
        try {
          var U = window.UC_UI;
          if (U && U.isInitialized && U.isInitialized() && U.isConsentRequired && U.isConsentRequired()) {
            Promise.resolve(U.denyAllConsents()).then(function () { if (U.closeCMP) U.closeCMP(); });
            return true;
          }
        } catch (e) {}
        return false;
      }

      function press(el) {
        try { el.click(); } catch (e) { return false; }
        return true;
      }

      function attempt() {
        if (done) return;
        if (apis()) return finish();
        var all = roots();
        for (var k = 0; k < known.length; k++) {
          for (var r = 0; r < all.length; r++) {
            var hit = all[r].querySelector(known[k]);
            if (hit && visible(hit) && press(hit)) return finish();
          }
        }
        for (var j = 0; j < all.length; j++) {
          var list = all[j].querySelectorAll(candidates);
          for (var i = 0; i < list.length; i++) {
            var el = list[i];
            var said = label(el);
            if (!said || !refusal.test(said)) continue;
            if (!visible(el) || !banner(el)) continue;
            if (press(el)) return finish();
          }
        }
      }

      function finish() {
        done = true;
        if (observer) observer.disconnect();
      }

      function soon() {
        if (done || pending) return;
        if (Date.now() - started > 20000) return finish();
        pending = true;
        setTimeout(function () { pending = false; attempt(); }, 250);
      }

      attempt();
      if (done) return;
      observer = new MutationObserver(soon);
      observer.observe(document.documentElement, { childList: true, subtree: true });
      [800, 2000, 4000, 8000, 14000].forEach(function (t) { setTimeout(soon, t); });
      setTimeout(finish, 20500);
    })();
    """#
}
