import UIKit
import WebKit

// chrome.debugger, for extensions that work a page for you — Claude's is the
// one this was made for. Chrome hands them its DevTools protocol; WebKit has
// none to hand, so the commands they use are answered here, over the tab's
// own web view: a picture of the page, a press, a key, words typed, a script.
//
// Only an extension whose manifest asks for "debugger" (checked in
// ExtensionShims.run, and said when it is added), only tabs it attached to,
// only web pages, and never a private tab.
@available(iOS 18.4, *)
@MainActor
final class ExtensionDebugger {
    static let shared = ExtensionDebugger()

    /// Tabs each extension is attached to, by the number it knows them by.
    private var attached: [String: [Int: Tab.ID]] = [:]

    private func refuse(_ what: String) -> Error { ExtensionShims.Unsupported(what: what) }

    func answer(_ api: String, _ args: [Any], for id: String, owner: Extensions) async throws -> Any? {
        if api == "debugger.attached" { return attached[id].map { Array($0.keys) } ?? [Int]() }
        let place = args.first as? [String: Any]
        guard let number = (place?["n"] as? NSNumber)?.intValue else { throw refuse("Either tab id or extension id must be specified.") }

        switch api {
        case "debugger.attach":
            guard let tab = ExtensionShims.located(place, owner: owner) else { throw refuse("No tab with given id \(number).") }
            guard ["http", "https"].contains(tab.address?.scheme?.lowercased() ?? "") else { throw refuse("Cannot access this page") }
            if attached[id]?[number] != nil { throw refuse("Another debugger is already attached to the tab with id: \(number).") }
            attached[id, default: [:]][number] = tab.id
            return nil
        case "debugger.detach":
            guard attached[id]?.removeValue(forKey: number) != nil else { throw refuse("Debugger is not attached to the tab with id: \(number).") }
            return nil
        case "debugger.send":
            guard let key = attached[id]?[number] else { throw refuse("Debugger is not attached to the tab with id: \(number).") }
            guard let tab = owner.visibleTabs.first(where: { $0.id == key }) else {
                attached[id]?[number] = nil
                throw refuse("No tab with given id \(number).")
            }
            let method = args.dropFirst().first as? String ?? ""
            return try await send(method, args.dropFirst(2).first as? [String: Any] ?? [:], to: tab, owner: owner)
        default:
            throw refuse("\(api) isn't available")
        }
    }

    func forget(_ id: String) { attached[id] = nil }

    private func send(_ method: String, _ params: [String: Any], to tab: Tab, owner: Extensions) async throws -> Any? {
        let web = tab.web
        guard ["http", "https"].contains(web.url?.scheme?.lowercased() ?? "") else { throw refuse("Cannot access this page") }
        switch method {
        case "Page.captureScreenshot":
            return try await picture(of: web, params)
        case "Page.getLayoutMetrics":
            return try await run("return __metrics();", in: web)
        case "Page.getFrameTree":
            return ["frameTree": ["frame": ["id": "main", "loaderId": String(web.url.hashValue), "url": web.url?.absoluteString ?? "",
                                            "securityOrigin": web.url.map { "\($0.scheme ?? "")://\($0.host() ?? "")" } ?? "",
                                            "mimeType": "text/html"] as [String: Any]] as [String: Any]]
        case "Page.bringToFront":
            owner.browser?.select(tab)
            return [String: Any]()
        case "Page.navigate":
            guard let url = (params["url"] as? String).flatMap(URL.init(string:)), ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            else { throw refuse("Cannot navigate to invalid URL") }
            web.load(URLRequest(url: url))
            return ["frameId": "main"]
        case "Page.reload":
            web.reload()
            return [String: Any]()
        case "Runtime.evaluate":
            return try await evaluate(params["expression"] as? String ?? "", in: web, wait: params["awaitPromise"] as? Bool ?? false)
        case "Input.dispatchMouseEvent":
            _ = try await run("return __mouse(p);", ["p": params], in: web)
            return [String: Any]()
        case "Input.insertText":
            _ = try await run("return __insert(p.text);", ["p": params], in: web)
            return [String: Any]()
        case "Input.dispatchKeyEvent":
            _ = try await run("return __key(p);", ["p": params], in: web)
            return [String: Any]()
        default:
            // Turning a domain on or off, focus, dialogs: nothing to do here.
            return [String: Any]()
        }
    }

    // MARK: a picture of the page

    /// What the page shows, its own corner at the picture's corner: the view
    /// also runs under the status bar and the pill, which a page's own
    /// coordinates know nothing of.
    private func picture(of web: WKWebView, _ params: [String: Any]) async throws -> Any? {
        let metrics = try? await run("return __metrics();", in: web) as? [String: Any]
        let inner = metrics?["cssLayoutViewport"] as? [String: Any]
        let width = (inner?["clientWidth"] as? NSNumber)?.doubleValue ?? web.bounds.width
        let height = (inner?["clientHeight"] as? NSNumber)?.doubleValue ?? web.bounds.height
        let scale = web.scrollView.zoomScale > 0 ? web.scrollView.zoomScale : 1
        let top = web.scrollView.adjustedContentInset.top, left = web.scrollView.adjustedContentInset.left
        var rect = CGRect(x: left, y: top, width: min(width * scale, web.bounds.width - left), height: min(height * scale, web.bounds.height - top))
        var times = 1.0
        if let clip = params["clip"] as? [String: Any] {
            let n = { (k: String) in (clip[k] as? NSNumber)?.doubleValue ?? 0 }
            let page = inner.map { (($0["pageX"] as? NSNumber)?.doubleValue ?? 0, ($0["pageY"] as? NSNumber)?.doubleValue ?? 0) } ?? (0, 0)
            let asked = CGRect(x: left + (n("x") - page.0) * scale, y: top + (n("y") - page.1) * scale, width: n("width") * scale, height: n("height") * scale)
            let seen = asked.intersection(rect)
            if !seen.isNull, seen.width >= 1, seen.height >= 1 { rect = seen }
            times = n("scale") > 0 ? n("scale") : 1
        }
        let config = WKSnapshotConfiguration()
        config.rect = rect
        if times != 1 { config.snapshotWidth = NSNumber(value: rect.width * times) }
        let image = try await web.takeSnapshot(configuration: config)
        let format = params["format"] as? String ?? "png"
        let quality = ((params["quality"] as? NSNumber)?.doubleValue ?? 80) / 100
        guard let data = format == "png" ? image.pngData() : image.jpegData(compressionQuality: quality) else { throw refuse("Unable to capture screenshot") }
        return ["data": data.base64EncodedString()]
    }

    // MARK: scripts

    private func run(_ body: String, _ arguments: [String: Any] = [:], in web: WKWebView) async throws -> Any? {
        try await web.callAsyncJavaScript(Self.hands + "\n" + body, arguments: arguments, in: nil, contentWorld: .page)
    }

    /// As the protocol answers it. `eval` gives a program's last value and a
    /// promise to wait for; a page whose policy forbids it stops it before
    /// it has run, and the program is then run by WebKit itself.
    private func evaluate(_ source: String, in web: WKWebView, wait: Bool) async throws -> Any? {
        let body = """
        const tell = (v) => {
          if (v === undefined) return { type: 'undefined' };
          if (v === null) return { type: 'object', subtype: 'null', value: null };
          const type = typeof v;
          if (type === 'bigint') return { type, unserializableValue: String(v) + 'n', description: String(v) + 'n' };
          if (type === 'number' && !isFinite(v)) return { type, unserializableValue: String(v), description: String(v) };
          if (type === 'function' || type === 'symbol') return { type, description: String(v) };
          let value;
          try { const s = JSON.stringify(v); value = s === undefined ? undefined : JSON.parse(s); } catch (e) { return { type, description: String(v) }; }
          const out = { type, value };
          if (Array.isArray(v)) out.subtype = 'array';
          return out;
        };
        const wrong = (e) => ({ result: { type: 'object', subtype: 'error' }, exceptionDetails: { exceptionId: 1, text: 'Uncaught', lineNumber: 0, columnNumber: 0,
          exception: (e instanceof Error) ? { type: 'object', subtype: 'error', className: e.name, description: String(e.stack && e.stack.includes(e.message) ? e.stack : e.name + ': ' + e.message) } : { ...tell(e), description: String(e) } } });
        let v;
        try { v = (0, eval)(source); }
        catch (e) {
          if (e instanceof EvalError || /unsafe-eval|Content Security Policy|call to eval/i.test(String(e && e.message))) return { search: 'eval' };
          if (e instanceof SyntaxError && /\\bawait\\b/.test(source)) return { search: 'await' };
          return wrong(e);
        }
        try { if (wait && v && typeof v.then === 'function') v = await v; return { result: tell(v) }; } catch (e) { return wrong(e); }
        """
        let first = try await web.callAsyncJavaScript(body, arguments: ["source": source, "wait": wait], in: nil, contentWorld: .page) as? [String: Any] ?? [:]
        guard let why = first["search"] as? String else { return first }
        if why == "await" {
            // Top-level await: the same program as an async function's body.
            let value = try? await web.callAsyncJavaScript("return await (async () => { \(source)\n })();", arguments: [:], in: nil, contentWorld: .page)
            return ["result": described(value ?? nil)]
        }
        do {
            let value = try await web.evaluateJavaScript(source, in: nil, contentWorld: .page)
            return ["result": described(value)]
        } catch {
            let words = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            return ["result": ["type": "object", "subtype": "error"],
                    "exceptionDetails": ["exceptionId": 1, "text": "Uncaught", "lineNumber": 0, "columnNumber": 0,
                                         "exception": ["type": "string", "value": words, "description": words]] as [String: Any]]
        }
    }

    private func described(_ value: Any?) -> [String: Any] {
        switch value {
        case nil: return ["type": "undefined"]
        case is NSNull: return ["type": "object", "subtype": "null", "value": NSNull()]
        case let words as String: return ["type": "string", "value": words]
        case let number as NSNumber:
            return ["type": CFGetTypeID(number) == CFBooleanGetTypeID() ? "boolean" : "number", "value": number]
        case let list as [Any]: return ["type": "object", "subtype": "array", "value": list]
        default: return ["type": "object", "value": value!]
        }
    }

    /// The hands: what the protocol's input commands do, done in the page.
    private static let hands = #"""
    const __metrics = () => {
      const v = window.visualViewport, d = document.documentElement;
      return {
        cssLayoutViewport: { pageX: Math.round(scrollX), pageY: Math.round(scrollY), clientWidth: innerWidth, clientHeight: innerHeight },
        cssVisualViewport: { offsetX: v ? v.offsetLeft : 0, offsetY: v ? v.offsetTop : 0, pageX: scrollX, pageY: scrollY, clientWidth: innerWidth, clientHeight: innerHeight, scale: v ? v.scale : 1, zoom: 1 },
        cssContentSize: { x: 0, y: 0, width: d.scrollWidth, height: d.scrollHeight },
        layoutViewport: { pageX: Math.round(scrollX), pageY: Math.round(scrollY), clientWidth: innerWidth, clientHeight: innerHeight },
        contentSize: { x: 0, y: 0, width: d.scrollWidth, height: d.scrollHeight },
      };
    };
    // What is under a point, through shadow roots and frames of the same site.
    const __under = (x, y) => {
      let root = document, el = null, win = window;
      for (let i = 0; i < 20; i++) {
        const next = root.elementFromPoint(x, y);
        if (!next || next === el) break;
        el = next;
        if (el.shadowRoot) { root = el.shadowRoot; continue; }
        if (el.tagName === 'IFRAME' || el.tagName === 'FRAME') {
          let doc = null;
          try { doc = el.contentDocument; } catch (e) {}
          if (!doc) break;
          const r = el.getBoundingClientRect();
          x -= r.left + el.clientLeft; y -= r.top + el.clientTop;
          root = doc; win = el.contentWindow; continue;
        }
        break;
      }
      return { el, x, y, win };
    };
    const __active = () => {
      let a = document.activeElement;
      for (let i = 0; a && i < 20; i++) {
        if (a.shadowRoot && a.shadowRoot.activeElement) { a = a.shadowRoot.activeElement; continue; }
        if (a.tagName === 'IFRAME') { try { if (a.contentDocument && a.contentDocument.activeElement) { a = a.contentDocument.activeElement; continue; } } catch (e) {} }
        break;
      }
      return a || document.body;
    };
    const __state = (window.__searchHands = window.__searchHands || { down: null, over: null });
    const __mods = (n) => ({ altKey: !!(n & 1), ctrlKey: !!(n & 2), metaKey: !!(n & 4), shiftKey: !!(n & 8) });
    const __editable = (el) => el && (el.isContentEditable || (/^(INPUT|TEXTAREA)$/.test(el.tagName) && !/^(button|submit|reset|checkbox|radio|file|color|range|image|hidden)$/i.test(el.type || '')));
    const __mouse = (p) => {
      const at = __under(p.x, p.y), el = at.el;
      if (!el) return false;
      const doc = el.ownerDocument, win = doc.defaultView || window;
      const which = { left: 0, middle: 1, right: 2, back: 3, forward: 4 }[p.button] ?? 0;
      const bits = { left: 1, right: 2, middle: 4 }[p.button] || 0;
      const base = { bubbles: true, cancelable: true, composed: true, view: win, clientX: at.x, clientY: at.y, screenX: p.x, screenY: p.y, ...__mods(p.modifiers || 0) };
      const point = { ...base, pointerId: 1, pointerType: 'mouse', isPrimary: true };
      const fire = (target, type, extra, Kind) => target.dispatchEvent(new (Kind || win.MouseEvent)(type, { ...(Kind === win.PointerEvent ? point : base), ...extra }));
      if (p.type === 'mouseWheel') {
        const wheel = new win.WheelEvent('wheel', { ...base, deltaX: p.deltaX || 0, deltaY: p.deltaY || 0 });
        if (!el.dispatchEvent(wheel)) return true;
        let box = el;
        while (box && box !== doc.body && box !== doc.documentElement) {
          const s = win.getComputedStyle(box);
          const tall = /(auto|scroll|overlay)/.test(s.overflowY) && box.scrollHeight > box.clientHeight + 1;
          const wide = /(auto|scroll|overlay)/.test(s.overflowX) && box.scrollWidth > box.clientWidth + 1;
          if ((p.deltaY && tall) || (p.deltaX && wide)) {
            const t = box.scrollTop, l = box.scrollLeft;
            box.scrollBy({ left: p.deltaX || 0, top: p.deltaY || 0, behavior: 'instant' });
            if (box.scrollTop !== t || box.scrollLeft !== l) return true;
          }
          box = box.parentElement || (box.getRootNode() && box.getRootNode().host);
        }
        win.scrollBy({ left: p.deltaX || 0, top: p.deltaY || 0, behavior: 'instant' });
        return true;
      }
      if (p.type === 'mouseMoved') {
        const buttons = p.buttons || 0;
        if (__state.over !== el) {
          if (__state.over && __state.over.isConnected) {
            fire(__state.over, 'pointerout', { buttons }, win.PointerEvent); fire(__state.over, 'mouseout', { buttons, relatedTarget: el });
            fire(__state.over, 'mouseleave', { buttons, bubbles: false });
          }
          fire(el, 'pointerover', { buttons }, win.PointerEvent); fire(el, 'mouseover', { buttons, relatedTarget: __state.over });
          fire(el, 'pointerenter', { buttons, bubbles: false }, win.PointerEvent); fire(el, 'mouseenter', { buttons, bubbles: false });
          __state.over = el;
        }
        fire(el, 'pointermove', { buttons }, win.PointerEvent);
        fire(el, 'mousemove', { buttons });
        return true;
      }
      if (p.type === 'mousePressed') {
        __state.down = el;
        fire(el, 'pointerdown', { button: which, buttons: bits, pressure: 0.5 }, win.PointerEvent);
        const go = fire(el, 'mousedown', { button: which, buttons: bits, detail: p.clickCount || 1 });
        if (go) {
          const field = el.closest('input, textarea, select, button, a[href], [tabindex], [contenteditable=""], [contenteditable="true"], label');
          const target = field && field.tagName === 'LABEL' ? field.control : field;
          if (target && typeof target.focus === 'function') target.focus({ preventScroll: true });
          else if (doc.activeElement && doc.activeElement !== doc.body) doc.activeElement.blur();
          if (target && __editable(target)) {
            if (p.clickCount >= 3 && typeof target.select === 'function') target.select();
            else if (p.clickCount >= 3 && target.isContentEditable) win.getSelection().selectAllChildren(target);
            else if (target.isContentEditable && doc.caretRangeFromPoint) {
              const r = doc.caretRangeFromPoint(at.x, at.y);
              if (r) { const s = win.getSelection(); s.removeAllRanges(); s.addRange(r); }
            }
          }
        }
        return true;
      }
      if (p.type === 'mouseReleased') {
        fire(el, 'pointerup', { button: which, buttons: 0 }, win.PointerEvent);
        fire(el, 'mouseup', { button: which, buttons: 0, detail: p.clickCount || 1 });
        const down = __state.down;
        __state.down = null;
        let both = el;
        if (down && down !== el) { both = null; for (let n = down; n; n = n.parentElement) if (n.contains(el)) { both = n; break; } }
        if (!both) return true;
        if (which === 2) { fire(both, 'contextmenu', { button: 2, buttons: 0 }); return true; }
        if (which === 1) { fire(both, 'auxclick', { button: 1 }); return true; }
        fire(both, 'click', { button: which, detail: p.clickCount || 1 });
        if (p.clickCount === 2) fire(both, 'dblclick', { button: which, detail: 2 });
        return true;
      }
      return false;
    };
    const __insert = (text) => {
      const el = __active(), doc = el.ownerDocument || document, win = doc.defaultView || window;
      if (!__editable(el)) return false;
      if (doc.execCommand('insertText', false, text)) return true;
      if (el.isContentEditable) return false;
      const proto = el.tagName === 'TEXTAREA' ? win.HTMLTextAreaElement.prototype : win.HTMLInputElement.prototype;
      const set = Object.getOwnPropertyDescriptor(proto, 'value').set;
      let start = el.value.length, end = start;
      try { if (el.selectionStart !== null) { start = el.selectionStart; end = el.selectionEnd; } } catch (e) {}
      set.call(el, el.value.slice(0, start) + text + el.value.slice(end));
      try { el.setSelectionRange(start + text.length, start + text.length); } catch (e) {}
      el.dispatchEvent(new win.InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: text }));
      return true;
    };
    const __key = (p) => {
      const el = __active(), doc = el.ownerDocument || document, win = doc.defaultView || window;
      const code = p.windowsVirtualKeyCode || p.nativeVirtualKeyCode || 0;
      const init = { key: p.key || p.text || '', code: p.code || '', keyCode: code, which: code, location: p.location || 0, repeat: !!p.autoRepeat, bubbles: true, cancelable: true, composed: true, view: win, ...__mods(p.modifiers || 0) };
      const key = (type) => {
        const e = new win.KeyboardEvent(type, init);
        try { Object.defineProperty(e, 'keyCode', { get: () => code }); Object.defineProperty(e, 'which', { get: () => code }); } catch (x) {}
        return el.dispatchEvent(e);
      };
      if (p.type === 'keyUp') { key('keyup'); return true; }
      if (p.type === 'char') { if (p.text) __insert(p.text); return true; }
      if (!key('keydown')) return false;
      const name = p.key || '', held = (p.modifiers || 0) & 6;
      for (const c of p.commands || []) { if (/^selectAll$/i.test(c)) { doc.execCommand('selectAll'); return true; } if (doc.execCommand(c)) return true; }
      if (held) {
        const l = name.toLowerCase();
        if (l === 'a') { if (el.select && __editable(el)) el.select(); else doc.execCommand('selectAll'); }
        else if (l === 'c') doc.execCommand('copy');
        else if (l === 'x') doc.execCommand('cut');
        else if (l === 'z') doc.execCommand((p.modifiers & 8) ? 'redo' : 'undo');
        return true;
      }
      const editing = __editable(el), view = win.innerHeight * 0.9;
      switch (name) {
        case 'Enter': {
          const typed = key('keypress');
          if (!typed) return true;
          if (el.tagName === 'TEXTAREA') __insert('\n');
          else if (el.isContentEditable) doc.execCommand((p.modifiers & 8) ? 'insertLineBreak' : 'insertParagraph');
          else if (el.tagName === 'INPUT' && el.form && !/^(button|reset|checkbox|radio)$/i.test(el.type)) {
            el.dispatchEvent(new win.Event('change', { bubbles: true }));
            const button = el.form.querySelector('button[type=submit], input[type=submit], input[type=image], button:not([type])');
            if (button) button.click(); else if (el.form.requestSubmit) el.form.requestSubmit(); else el.form.submit();
          } else if (/^(A|BUTTON|SUMMARY)$/.test(el.tagName) || el.tagName === 'INPUT') el.click();
          return true;
        }
        case 'Backspace': if (editing) doc.execCommand('delete'); return true;
        case 'Delete': if (editing) doc.execCommand('forwardDelete'); return true;
        case ' ': if (!editing && /^(BUTTON|INPUT|SUMMARY)$/.test(el.tagName)) { el.click(); return true; } break;
        case 'Tab': {
          const all = [...doc.querySelectorAll('a[href], button, input, select, textarea, [tabindex], [contenteditable="true"]')]
            .filter((n) => !n.disabled && n.tabIndex >= 0 && n.getClientRects().length && n.type !== 'hidden');
          const i = all.indexOf(el), next = all[(i + ((p.modifiers & 8) ? -1 : 1) + all.length) % all.length];
          if (next) { next.focus(); if (next.select && __editable(next)) next.select(); }
          return true;
        }
        case 'ArrowLeft': case 'ArrowRight': case 'ArrowUp': case 'ArrowDown': case 'Home': case 'End':
          if (editing) {
            const s = win.getSelection(), how = (p.modifiers & 8) ? 'extend' : 'move';
            const to = { ArrowLeft: ['left', 'character'], ArrowRight: ['right', 'character'], ArrowUp: ['backward', 'line'], ArrowDown: ['forward', 'line'], Home: ['backward', 'lineboundary'], End: ['forward', 'lineboundary'] }[name];
            if (el.isContentEditable) s.modify(how, to[0], to[1]);
            else try {
              let at = name === 'ArrowLeft' ? Math.max(0, el.selectionStart - 1) : name === 'ArrowRight' ? Math.min(el.value.length, el.selectionEnd + 1) : /Home|ArrowUp/.test(name) ? 0 : el.value.length;
              el.setSelectionRange(how === 'extend' ? Math.min(el.selectionStart, at) : at, how === 'extend' ? Math.max(el.selectionEnd, at) : at);
            } catch (e) {}
          } else if (name === 'ArrowUp' || name === 'ArrowDown') win.scrollBy(0, name === 'ArrowUp' ? -40 : 40);
          else if (name === 'Home') win.scrollTo(0, 0);
          else if (name === 'End') win.scrollTo(0, doc.documentElement.scrollHeight);
          return true;
        case 'PageUp': win.scrollBy(0, -view); return true;
        case 'PageDown': win.scrollBy(0, view); return true;
      }
      const text = p.type === 'rawKeyDown' ? '' : (p.text || '');
      if (text && key('keypress')) __insert(text === '\r' ? '\n' : text);
      return true;
    };
    """#
}
