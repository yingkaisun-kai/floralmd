// Modified from Edmund by Yingkai Sun for FloralMD.
import Testing
import WebKit
@testable import FloralMDCore

@Suite("ReadModeWebView — navigation delegate")
@MainActor
struct ReadModeWebViewTests {

    // Regression guard: WebKit only calls a delegate method it passes
    // `respondsToSelector:`. Under Swift 6 the completion-handler form of
    // `decidePolicyFor` fails to satisfy the (concurrency-annotated) protocol
    // requirement and gets registered under the wrong selector, so WebKit never
    // calls it and every link navigates in-view. The async form registers the
    // correct selector — assert that here so the fix can't silently regress.
    @Test("nav delegate responds to the real decidePolicyFor selector")
    func decidePolicySelectorRegistered() {
        let webView = ReadModeWebView()
        let delegate = webView.navigationDelegate as? NSObject
        #expect(delegate != nil)
        let selector = NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")
        #expect(delegate?.responds(to: selector) == true)
    }

    @Test("Transparent background clears WebKit's under-page fill")
    func transparentBackground() {
        let webView = ReadModeWebView()
        webView.usesTransparentBackground = true
        #expect(webView.underPageBackgroundColor?.alphaComponent == 0)
        webView.usesTransparentBackground = false
        #expect(!webView.usesTransparentBackground)
    }

    @Test("scroll-position bridge parser accepts only complete pairs")
    func scrollPositionParser() {
        let parsed = ReadModeWebView.parseScrollPosition("42,0.375")
        #expect(parsed?.line == 42)
        #expect(parsed?.fraction == 0.375)
        #expect(ReadModeWebView.parseScrollPosition("") == nil)
        #expect(ReadModeWebView.parseScrollPosition("42") == nil)
        #expect(ReadModeWebView.parseScrollPosition("line,0.5") == nil)
    }

    @Test("navigation policy only allows read-mode routes and browser handoffs")
    func navigationPolicyClassifiesSchemes() {
        #expect(ReadModeNavigationPolicy.decision(
            for: URL(string: "about:blank#section")!,
            navigationType: .linkActivated) == .allow)
        #expect(ReadModeNavigationPolicy.decision(
            for: URL(string: "x-floralmd-wiki:Note%23Heading")!,
            navigationType: .linkActivated) == .openWiki("Note#Heading"))
        #expect(ReadModeNavigationPolicy.decision(
            for: URL(string: "x-floralmd-link:notes%2Ftoday.md")!,
            navigationType: .linkActivated) == .openInternal("notes/today.md"))
        #expect(ReadModeNavigationPolicy.decision(
            for: URL(string: "https://example.com")!,
            navigationType: .linkActivated) == .openExternal(URL(string: "https://example.com")!))
        #expect(ReadModeNavigationPolicy.decision(
            for: URL(string: "file:///etc/passwd")!,
            navigationType: .linkActivated) == .cancel)
        #expect(ReadModeNavigationPolicy.decision(
            for: URL(string: "ftp://example.com/file")!,
            navigationType: .linkActivated) == .cancel)
        #expect(ReadModeNavigationPolicy.decision(
            for: URL(string: "about:blank")!,
            navigationType: .reload) == .reload)
    }
}
