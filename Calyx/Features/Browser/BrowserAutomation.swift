//
//  BrowserAutomation.swift
//  Calyx
//

import Foundation

struct BrowserAutomationResponse {
    let ok: Bool
    let value: String?
    let error: String?
    let pageURL: String?
}

enum BrowserAutomation {

    // MARK: - Selector Resolution

    static func resolveSelector(_ selector: String) -> String {
        guard selector.hasPrefix("@") else { return selector }
        let ref = String(selector.dropFirst())
        return "[data-calyx-ref=\"\(ref)\"]"
    }

    // MARK: - IIFE Wrapper

    static func wrap(_ body: String) -> String {
        """
        (() => {
            try {
                \(body)
                return JSON.stringify({
                    ok: true,
                    value: result,
                    error: null,
                    pageURL: location.href
                });
            } catch (e) {
                return JSON.stringify({
                    ok: false,
                    value: null,
                    error: e.message || String(e),
                    pageURL: location.href
                });
            }
        })()
        """
    }

    // MARK: - Snapshot

    static func snapshot(maxDepth: Int = 12, maxElements: Int = 500, maxTextLength: Int = 80) -> String {
        wrap("""
        let refCount = 0;
        const maxD = \(maxDepth);
        const maxE = \(maxElements);
        const maxT = \(maxTextLength);
        let count = 0;
        function walk(el, depth) {
            if (depth > maxD || count >= maxE) return null;
            count++;
            const ref = 'e' + count;
            el.setAttribute('data-calyx-ref', ref);
            const tag = el.tagName.toLowerCase();
            const role = el.getAttribute('role') || '';
            let text = (el.innerText || '').trim();
            if (text.length > maxT) text = text.substring(0, maxT) + '...';
            const children = [];
            for (const child of el.children) {
                if (count >= maxE) break;
                const node = walk(child, depth + 1);
                if (node) children.push(node);
            }
            return { tag, role, ref, text, children };
        }
        const tree = walk(document.body, 0);
        const result = JSON.stringify(tree);
        """)
    }

    // MARK: - Actions

    static func click(selector: String) -> String {
        let sel = resolveSelector(selector)
        let escaped = escapeJS(sel)
        return wrap("""
        const el = document.querySelector('\(escaped)');
        if (!el) throw new Error('Element not found: \(escaped)');
        el.click();
        const result = 'clicked';
        """)
    }

    static func fill(selector: String, value: String) -> String {
        let sel = resolveSelector(selector)
        let escapedSel = escapeJS(sel)
        let escapedVal = escapeJS(value)
        return wrap("""
        const el = document.querySelector('\(escapedSel)');
        if (!el) throw new Error('Element not found: \(escapedSel)');
        el.value = '\(escapedVal)';
        el.dispatchEvent(new Event('input', {bubbles: true}));
        el.dispatchEvent(new Event('change', {bubbles: true}));
        const result = 'filled';
        """)
    }

    static func type(text: String) -> String {
        let escaped = escapeJS(text)
        return wrap("""
        const text = '\(escaped)';
        const el = document.activeElement || document.body;
        for (const ch of text) {
            el.dispatchEvent(new KeyboardEvent('keydown', {key: ch, bubbles: true}));
            el.dispatchEvent(new KeyboardEvent('keypress', {key: ch, bubbles: true}));
            el.dispatchEvent(new InputEvent('input', {data: ch, bubbles: true}));
            el.dispatchEvent(new KeyboardEvent('keyup', {key: ch, bubbles: true}));
        }
        const result = 'typed';
        """)
    }

    static func press(key: String) -> String {
        let escaped = escapeJS(key)
        return wrap("""
        const el = document.activeElement || document.body;
        el.dispatchEvent(new KeyboardEvent('keydown', {key: '\(escaped)', bubbles: true}));
        el.dispatchEvent(new KeyboardEvent('keyup', {key: '\(escaped)', bubbles: true}));
        const result = 'pressed';
        """)
    }

    static func select(selector: String, value: String) -> String {
        let sel = resolveSelector(selector)
        let escapedSel = escapeJS(sel)
        let escapedVal = escapeJS(value)
        return wrap("""
        const el = document.querySelector('\(escapedSel)');
        if (!el) throw new Error('Element not found: \(escapedSel)');
        el.value = '\(escapedVal)';
        el.dispatchEvent(new Event('change', {bubbles: true}));
        const result = 'selected';
        """)
    }

    static func check(selector: String) -> String {
        let sel = resolveSelector(selector)
        let escaped = escapeJS(sel)
        return wrap("""
        const el = document.querySelector('\(escaped)');
        if (!el) throw new Error('Element not found: \(escaped)');
        el.checked = true;
        el.dispatchEvent(new Event('change', {bubbles: true}));
        const result = 'checked';
        """)
    }

    static func uncheck(selector: String) -> String {
        let sel = resolveSelector(selector)
        let escaped = escapeJS(sel)
        return wrap("""
        const el = document.querySelector('\(escaped)');
        if (!el) throw new Error('Element not found: \(escaped)');
        el.checked = false;
        el.dispatchEvent(new Event('change', {bubbles: true}));
        const result = 'unchecked';
        """)
    }

    static func getText(selector: String) -> String {
        let sel = resolveSelector(selector)
        let escaped = escapeJS(sel)
        return wrap("""
        const el = document.querySelector('\(escaped)');
        if (!el) throw new Error('Element not found: \(escaped)');
        const result = el.innerText || '';
        """)
    }

    static func getHTML(selector: String, maxLength: Int = 512000) -> String {
        let sel = resolveSelector(selector)
        let escaped = escapeJS(sel)
        return wrap("""
        const el = document.querySelector('\(escaped)');
        if (!el) throw new Error('Element not found: \(escaped)');
        let html = el.outerHTML || '';
        if (html.length > \(maxLength)) html = html.substring(0, \(maxLength));
        const result = html;
        """)
    }

    static func eval(code: String) -> String {
        wrap("""
        const result = (() => { return \(code); })();
        """)
    }

    static func wait(selector: String?, text: String?, url: String?, timeout: Int) -> String {
        var condition: String
        if let selector {
            let sel = resolveSelector(selector)
            let escaped = escapeJS(sel)
            condition = "document.querySelector('\(escaped)')"
        } else if let text {
            let escaped = escapeJS(text)
            condition = "document.body && document.body.innerText.includes('\(escaped)')"
        } else if let url {
            let escaped = escapeJS(url)
            condition = "location.href.includes('\(escaped)')"
        } else {
            condition = "true"
        }

        return """
        try {
            const result = await new Promise((resolve, reject) => {
                const timeout = \(timeout);
                if (\(condition)) { resolve('found'); return; }
                const observer = new MutationObserver(() => {
                    if (\(condition)) {
                        observer.disconnect();
                        resolve('found');
                    }
                });
                observer.observe(document.documentElement, {childList: true, subtree: true, characterData: true, attributes: true});
                setTimeout(() => {
                    observer.disconnect();
                    reject(new Error('Timeout after ' + timeout + 'ms'));
                }, timeout);
            });
            return JSON.stringify({
                ok: true,
                value: result,
                error: null,
                pageURL: location.href
            });
        } catch (e) {
            return JSON.stringify({
                ok: false,
                value: null,
                error: e.message || String(e),
                pageURL: location.href
            });
        }
        """
    }

    static func clearRefs() -> String {
        wrap("""
        document.querySelectorAll('[data-calyx-ref]').forEach(el => {
            el.removeAttribute('data-calyx-ref');
        });
        const result = 'cleared';
        """)
    }

    // MARK: - DOM Inspection

    static func getAttribute(selector: String, attribute: String) -> String {
        let sel = resolveSelector(selector)
        let escapedSel = escapeJS(sel)
        let escapedAttr = escapeJS(attribute)
        return wrap("""
        const el = document.querySelector('\(escapedSel)');
        if (!el) throw new Error('Element not found: \(escapedSel)');
        const val = el.getAttribute('\(escapedAttr)');
        const result = val === null ? 'null' : val;
        """)
    }

    static func getLinks(maxItems: Int = 100) -> String {
        wrap("""
        const els = Array.from(document.querySelectorAll('a[href]')).slice(0, \(maxItems));
        const result = JSON.stringify(els.map(a => {
            let text = (a.innerText || '').trim();
            if (text.length > 200) text = text.substring(0, 200);
            return { text, href: a.href };
        }));
        """)
    }

    static func getInputs(maxItems: Int = 100) -> String {
        wrap("""
        const els = Array.from(document.querySelectorAll('input, select, textarea')).slice(0, \(maxItems));
        const result = JSON.stringify(els.map(el => {
            let val = (el.value || '');
            if (val.length > 200) val = val.substring(0, 200);
            let ph = (el.placeholder || '');
            if (ph.length > 200) ph = ph.substring(0, 200);
            return {
                tag: el.tagName.toLowerCase(),
                type: el.type || '',
                name: el.name || '',
                id: el.id || '',
                value: val,
                placeholder: ph
            };
        }));
        """)
    }

    static func isVisible(selector: String) -> String {
        let sel = resolveSelector(selector)
        let escaped = escapeJS(sel)
        return wrap("""
        const el = document.querySelector('\(escaped)');
        let result;
        if (!el) {
            result = 'false';
        } else if (typeof el.checkVisibility === 'function') {
            result = el.checkVisibility() ? 'true' : 'false';
        } else {
            const s = getComputedStyle(el);
            const r = el.getBoundingClientRect();
            result = (s.display !== 'none' && s.visibility !== 'hidden' && parseFloat(s.opacity) > 0 && r.width > 0 && r.height > 0) ? 'true' : 'false';
        }
        """)
    }

    // MARK: - Interaction

    static func hover(selector: String) -> String {
        let sel = resolveSelector(selector)
        let escaped = escapeJS(sel)
        return wrap("""
        const el = document.querySelector('\(escaped)');
        if (!el) throw new Error('Element not found: \(escaped)');
        el.dispatchEvent(new PointerEvent('pointerover', {bubbles: true}));
        el.dispatchEvent(new PointerEvent('pointerenter', {bubbles: false}));
        el.dispatchEvent(new MouseEvent('mouseover', {bubbles: true}));
        el.dispatchEvent(new MouseEvent('mouseenter', {bubbles: false}));
        const result = 'hovered';
        """)
    }

    static func scroll(direction: String, amount: Int, selector: String? = nil) -> String {
        let dx: String
        let dy: String
        switch direction {
        case "up": dx = "0"; dy = "-\(amount)"
        case "down": dx = "0"; dy = "\(amount)"
        case "left": dx = "-\(amount)"; dy = "0"
        case "right": dx = "\(amount)"; dy = "0"
        default: preconditionFailure("Invalid direction '\(direction)' — handler must validate before calling")
        }

        if let selector {
            let sel = resolveSelector(selector)
            let escaped = escapeJS(sel)
            return wrap("""
            const el = document.querySelector('\(escaped)');
            if (!el) throw new Error('Element not found: \(escaped)');
            el.scrollBy(\(dx), \(dy));
            const result = JSON.stringify({scrolled: true, target: 'element', x: el.scrollLeft, y: el.scrollTop});
            """)
        } else {
            return wrap("""
            window.scrollBy(\(dx), \(dy));
            const result = JSON.stringify({scrolled: true, target: 'window', x: window.scrollX, y: window.scrollY});
            """)
        }
    }

    // MARK: - Response Parsing

    static func parseResponse(_ jsonString: String) -> BrowserAutomationResponse {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = json["ok"] as? Bool else {
            return BrowserAutomationResponse(
                ok: false,
                value: nil,
                error: "Failed to parse response",
                pageURL: nil
            )
        }

        let value: String?
        if let str = json["value"] as? String {
            value = str
        } else if let num = json["value"] as? NSNumber {
            value = num.stringValue
        } else if json["value"] is NSNull || json["value"] == nil {
            value = nil
        } else {
            // Arrays, dicts, etc — serialize back to JSON
            if let v = json["value"],
               let d = try? JSONSerialization.data(withJSONObject: v),
               let s = String(data: d, encoding: .utf8) {
                value = s
            } else {
                value = String(describing: json["value"]!)
            }
        }
        let error = json["error"] as? String
        let pageURL = json["pageURL"] as? String

        return BrowserAutomationResponse(
            ok: ok,
            value: value,
            error: error,
            pageURL: pageURL
        )
    }

    // MARK: - Private Helpers

    private static func escapeJS(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\0", with: "\\0")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
