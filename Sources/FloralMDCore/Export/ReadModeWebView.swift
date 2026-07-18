// Modified from Edmund by Yingkai Sun for FloralMD.
import AppKit
import WebKit

// MARK: - ReadModeWebView
//
// The WKWebView that backs Read mode. It is a pure renderer of the user's own
// document: JavaScript is disabled (plus a `script-src 'none'` CSP meta in the
// page itself), all assets are inlined (so no file/network reach), raw HTML
// passes through per GFM but filtered by `HTMLRenderer.filterRawHTML`
// (tagfilter + hardening), and navigation is intercepted — internal scrolling
// stays, external links open in the default browser, and the view never
// navigates away from the rendered document (§G, ARCHITECTURE §10).
//
// The navigation delegate is a *separate* object (not the webview itself). A
// WKWebView that is its own `navigationDelegate` does not reliably receive the
// policy callbacks, so link clicks would navigate in-view instead of opening
// externally; a dedicated, retained coordinator fixes that.
@MainActor
public final class ReadModeWebView: WKWebView {

    private let coordinator = ReadModeNavigationCoordinator()

    public init() {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        // QUIRK: `isInspectable` (macOS 13.3+) marks the webview as inspectable
        // but does NOT add the "Inspect Element" context menu on its own. The
        // legacy `developerExtrasEnabled` preference key is what actually shows
        // the menu item. Both must be set for right-click → Inspect Element to
        // work; the developer tools must also be enabled in Safari's settings.
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        super.init(frame: .zero, configuration: config)
        coordinator.owner = self
        navigationDelegate = coordinator
        if #available(macOS 13.3, *) { isInspectable = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Called when the user activates a `[[wikilink]]` — the (decoded) target is
    /// routed through the app's document graph rather than navigating the webview.
    public var onOpenWikiLink: ((String) -> Void)?

    /// Called when the user activates a relative/internal markdown link
    /// destination (e.g. `[text](other.md)`), routed the same way.
    public var onOpenInternalLink: ((String) -> Void)?

    /// Called once a rendered document and any pending viewport restore are ready.
    public var onLoadFinished: (() -> Void)?

    /// Lets the document window supply its own translucent background while
    /// leaving rendered text and inlined assets fully opaque.
    public var usesTransparentBackground = false {
        didSet {
            guard oldValue != usesTransparentBackground else { return }
            underPageBackgroundColor = usesTransparentBackground ? .clear : nil
            reloadHTML()
        }
    }

    /// The most recent render inputs, so the view can re-render itself when the
    /// system appearance flips (light ↔ dark) without the document re-driving it.
    private var pending: (markdown: String, theme: EditorTheme,
                          callouts: [String: CalloutStyle], baseURL: URL?,
                          options: ReadRenderOptions)?

    private var pendingScrollRestore: (line: Int, fraction: Double)?
    private var loadGeneration = 0
    private var hasLoadedOnce = false
    private var lastLoadedHTML: String?

    /// Renders `markdown` with the given theme; appearance is resolved from the
    /// view itself. `baseURL` is the document's directory (for resolving relative
    /// image paths to inline).
    public func render(markdown: String,
                       theme: EditorTheme,
                       callouts: [String: CalloutStyle],
                       baseURL: URL? = nil,
                       options: ReadRenderOptions = .default) {
        pending = (markdown, theme, callouts, baseURL, options)
        reloadHTML()
    }

    public func setPendingScrollRestore(line: Int, fraction: Double) {
        pendingScrollRestore = (line: line, fraction: fraction)
    }

    func reloadHTML() {
        guard let p = pending else { return }
        guard hasLoadedOnce else {
            hasLoadedOnce = true
            performLoad(p)
            return
        }
        guard pendingScrollRestore == nil else {
            performLoad(p)
            return
        }
        let generation = loadGeneration
        readScrollPosition { [weak self] restored in
            guard let self, self.loadGeneration == generation else { return }
            self.pendingScrollRestore = restored
            self.loadGeneration += 1
            self.performLoad(p)
        }
    }

    private func performLoad(_ p: (markdown: String, theme: EditorTheme,
                                   callouts: [String: CalloutStyle], baseURL: URL?,
                                   options: ReadRenderOptions)) {
        let dark = AppearanceResolver.isDark(effectiveAppearance)
        underPageBackgroundColor = usesTransparentBackground
            ? .clear : (NSColor(hex: dark ? "#1e1e1e" : "#ffffff") ?? .textBackgroundColor)
        let html = DocumentHTML.full(markdown: p.markdown, theme: p.theme,
                                     callouts: p.callouts, dark: dark,
                                     baseURL: p.baseURL, options: p.options,
                                     transparentBackground: usesTransparentBackground)
        guard html != lastLoadedHTML else {
            applyPendingScrollRestoreAndNotify()
            return
        }
        lastLoadedHTML = html
        loadHTMLString(html, baseURL: ReadModeNavigationPolicy.trustedBaseURL)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        reloadHTML()
    }

    fileprivate func handleDidFinishLoad() {
        applyPendingScrollRestoreAndNotify()
    }

    private func applyPendingScrollRestoreAndNotify() {
        if let restore = pendingScrollRestore {
            pendingScrollRestore = nil
            setScrollPosition(line: restore.line, fraction: restore.fraction)
        }
        onLoadFinished?()
    }

    // Host-injected JavaScript remains available while page/content JavaScript
    // stays disabled. Templates below contain numeric Swift values only — never
    // user or document content — so the renderer's security boundary is intact.
    public func setScrollPosition(line: Int, fraction: Double) {
        let clamped = min(max(fraction, 0), 1)
        let js = """
        (function() { \
        var el = document.getElementById('floralmd-l\(line)'); \
        if (el) { var se = document.scrollingElement; \
        se.scrollTop = el.getBoundingClientRect().top + se.scrollTop + \(String(describing: clamped)) * el.offsetHeight; } \
        })()
        """
        evaluateJavaScript(js, completionHandler: nil)
    }

    public func readScrollPosition(completion: @escaping ((line: Int, fraction: Double)?) -> Void) {
        let js = """
        (function() {
          var nodes = document.querySelectorAll('[id^="floralmd-l"]');
          if (nodes.length === 0) return '';
          var top = document.scrollingElement.scrollTop;
          var chosen = null;
          for (var i = 0; i < nodes.length; i++) {
            var elTop = nodes[i].getBoundingClientRect().top + top;
            if (elTop <= top + 1) { chosen = nodes[i]; } else { break; }
          }
          var fraction;
          if (!chosen) { chosen = nodes[0]; fraction = 0; }
          else {
            var chosenTop = chosen.getBoundingClientRect().top + top;
            fraction = (top - chosenTop) / Math.max(1, chosen.offsetHeight);
            if (fraction < 0) fraction = 0;
            if (fraction > 1) fraction = 1;
          }
          return chosen.id.slice(10) + ',' + fraction;
        })()
        """
        evaluateJavaScript(js) { result, error in
            Task { @MainActor in
                guard error == nil, let string = result as? String else {
                    completion(nil)
                    return
                }
                completion(Self.parseScrollPosition(string))
            }
        }
    }

    internal static func parseScrollPosition(_ string: String) -> (line: Int, fraction: Double)? {
        guard !string.isEmpty else { return nil }
        let parts = string.split(separator: ",", maxSplits: 1)
        guard parts.count == 2,
              let line = Int(parts[0]),
              let fraction = Double(parts[1]) else { return nil }
        return (line: line, fraction: fraction)
    }
}

// MARK: - Navigation policy

/// Intercepts navigation for Read mode: the initial load and in-page anchor
/// scrolls proceed; any link the user activates opens in the default browser and
/// the read view stays put.
@MainActor
private final class ReadModeNavigationCoordinator: NSObject, WKNavigationDelegate {

    /// Weak back-reference so the coordinator can re-inject HTML on reload
    /// without needing the webview to be its own delegate.
    weak var owner: ReadModeWebView?

    // QUIRK: use the *async* form of this delegate method, not the
    // completion-handler form. Under Swift 6 the SDK annotates the
    // completion-handler's closure (`@MainActor @Sendable`); a plain
    // `@escaping (WKNavigationActionPolicy) -> Void` does NOT match the
    // requirement, so the compiler exposes it under the naïve selector
    // `webView:decidePolicyFor:decisionHandler:` instead of the real
    // `webView:decidePolicyForNavigationAction:decisionHandler:`. WebKit's
    // `respondsToSelector:` check then fails and the method is never called —
    // every link navigates in-view. The async form matches the requirement
    // (`webView(_:decidePolicyFor:)`) exactly and registers the correct selector.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // QUIRK: the page is loaded with an explicit `about:blank` base URL.
        // A user-triggered or WebKit-triggered
        // reload navigates back to `about:blank` and clears the content. Intercept
        // it and re-inject the HTML ourselves instead of allowing the blank reload.
        switch ReadModeNavigationPolicy.decision(for: navigationAction.request.url,
                                                 navigationType: navigationAction.navigationType) {
        case .reload:
            owner?.reloadHTML()
            return .cancel
        case .openWiki(let target):
            owner?.onOpenWikiLink?(target)
            return .cancel
        case .openInternal(let target):
            owner?.onOpenInternalLink?(target)
            return .cancel
        case .openExternal(let url):
            NSWorkspace.shared.open(url)
            return .cancel
        case .allow:
            return .allow
        case .cancel:
            return .cancel
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        owner?.handleDidFinishLoad()
    }
}

// MARK: - Navigation classifier

enum ReadModeNavigationPolicy {

    static let trustedBaseURL = URL(string: "about:blank")!

    enum Decision: Equatable {
        case allow
        case reload
        case openWiki(String)
        case openInternal(String)
        case openExternal(URL)
        case cancel
    }

    /// Classifies read-mode navigation without touching WebKit/AppKit state. The
    /// generated document is self-contained and loaded against `about:blank`, so
    /// only in-document anchors, FloralMD's private schemes, and browser handoffs are
    /// expected. `file:` and other explicit schemes stay out of the webview.
    static func decision(for url: URL?, navigationType: WKNavigationType) -> Decision {
        if navigationType == .reload { return .reload }
        guard let url else { return .allow }
        let scheme = url.scheme?.lowercased()

        // `[[wikilink]]`s and relative/internal markdown links carry their target
        // in a private scheme (the renderer classifies them). Decode the target
        // and route it through the app's document graph.
        if scheme == HTMLRenderer.wikiScheme {
            return .openWiki(decodeTarget(url, scheme: HTMLRenderer.wikiScheme))
        }
        if scheme == HTMLRenderer.linkScheme {
            return .openInternal(decodeTarget(url, scheme: HTMLRenderer.linkScheme))
        }
        // Decide by URL scheme, not navigation type: WebKit does not reliably
        // report `.linkActivated` for every click. Real web schemes are handed to
        // the user's browser; `about:` covers the initial document and in-page
        // `#fragment` scrolls; anything else is not fetched in the webview.
        if scheme == "http" || scheme == "https" || scheme == "mailto" {
            return .openExternal(url)
        }
        if scheme == nil || scheme == "about" {
            return .allow
        }
        return .cancel
    }

    /// Recovers the percent-decoded target from a private-scheme URL
    /// (`scheme:encoded`), which has no `//` authority.
    private static func decodeTarget(_ url: URL, scheme: String) -> String {
        let raw = String(url.absoluteString.dropFirst(scheme.count + 1))
        return raw.removingPercentEncoding ?? raw
    }
}
