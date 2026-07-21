// Modified from Edmund by Yingkai Sun for FloralMD.
import Testing
import AppKit
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

    @Test("Content JavaScript stays disabled")
    func contentJavaScriptDisabled() {
        let webView = ReadModeWebView()
        #expect(webView.configuration.defaultWebpagePreferences.allowsContentJavaScript == false)
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
            for: URL(string: "x-floralmd-copy:CB5E3B63-A8C2-4F07-A89D-6105CC58B77E:bGV0IHggPSAx")!,
            navigationType: .linkActivated) == .copyCode(
                "CB5E3B63-A8C2-4F07-A89D-6105CC58B77E:bGV0IHggPSAx"
            ))
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

    @Test("Clicking a rendered copy button writes raw code and announces localized feedback")
    func copyButtonInteraction() async throws {
        let pasteboard = NSPasteboard(name: .init("FloralMDTests.copy.\(UUID().uuidString)"))
        let webView = ReadModeWebView(copyPasteboard: pasteboard)
        webView.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        let expected = "let 文本 = \"#%<&\"\nprint(文本)"
        let markdown = "```swift\n\(expected)\n```"

        await withCheckedContinuation { continuation in
            webView.onLoadFinished = {
                webView.onLoadFinished = nil
                continuation.resume()
            }
            webView.render(
                markdown: markdown,
                theme: .default,
                callouts: Callout.defaultStyles,
                copyStrings: ReadModeCopyStrings(
                    copyCode: "复制代码",
                    copied: "已复制",
                    announcement: "代码已复制"
                )
            )
        }

        let clicked = try await evaluateBoolean(
            """
            (function() {
              var button = document.querySelector('.code-copy-btn');
              if (!button) return false;
              button.click();
              return true;
            })()
            """,
            in: webView
        )
        #expect(clicked)

        for _ in 0..<100 where pasteboard.string(forType: .string) != expected {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(pasteboard.string(forType: .string) == expected)

        let feedback = try await evaluateString(
            """
            (function() {
              var button = document.querySelector('.code-copy-btn');
              var status = document.querySelector('.code-copy-status');
              var confirmation = button.querySelector('.code-copy-confirmation');
              return button.classList.contains('copied') + '|' +
                     button.getAttribute('aria-label') + '|' + status.textContent + '|' +
                     getComputedStyle(confirmation).display;
            })()
            """,
            in: webView
        )
        #expect(feedback == "true|已复制|代码已复制|flex")
        #expect(await waitUntil {
            let restored = try? await evaluateString(
                """
                (function() {
                  var button = document.querySelector('.code-copy-btn');
                  var status = document.querySelector('.code-copy-status');
                  return button.classList.contains('copied') + '|' +
                         button.getAttribute('aria-label') + '|' + status.textContent;
                })()
                """,
                in: webView
            )
            return restored == "false|复制代码|"
        })
        pasteboard.clearContents()
    }

    @Test("Code block controls share the top-right row without covering code at narrow widths")
    func codeBlockControlLayout() async throws {
        let webView = ReadModeWebView()
        webView.frame = NSRect(x: 0, y: 0, width: 280, height: 480)
        var didFinishLoad = false
        webView.onLoadFinished = { didFinishLoad = true }
        webView.render(
            markdown: """
            ```extraordinarily-long-language-identifier-for-layout
            let value = 42
            ```

            ```text
            plain text
            ```

            ```
            no language
            ```
            """,
            theme: .default,
            callouts: Callout.defaultStyles
        )
        #expect(await waitUntil { didFinishLoad })

        let metrics = try await evaluateString(
            """
            (function() {
              var wrap = document.querySelector('.code-block-wrap').getBoundingClientRect();
              var controls = document.querySelector('.code-block-controls').getBoundingClientRect();
              var label = document.querySelector('.code-language-label');
              var labelRect = label.getBoundingClientRect();
              var buttonRect = document.querySelector('.code-copy-btn').getBoundingClientRect();
              var codeRect = document.querySelector('.code-block-wrap code').getBoundingClientRect();
              return [
                document.querySelectorAll('.code-language-label').length,
                controls.right <= wrap.right + 0.5,
                controls.left >= wrap.left - 0.5,
                labelRect.right + 5.5 <= buttonRect.left,
                controls.bottom <= codeRect.top,
                label.scrollWidth > label.clientWidth,
                getComputedStyle(label).textOverflow
              ].join('|');
            })()
            """,
            in: webView
        )
        #expect(metrics == "1|true|true|true|true|true|ellipsis")
    }

    private func evaluateBoolean(_ script: String, in webView: WKWebView) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: result as? Bool ?? false) }
            }
        }
    }

    private func evaluateString(_ script: String, in webView: WKWebView) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: result as? String ?? "") }
            }
        }
    }

    @Test("Task checkbox and first text line share one vertical center across font sizes")
    func taskCheckboxAlignment() async throws {
        let webView = ReadModeWebView()
        webView.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        var didFinishLoad = false
        webView.onLoadFinished = { didFinishLoad = true }
        webView.render(
            markdown: "- [ ] first item\n- [ ] second item",
            theme: .default,
            callouts: Callout.defaultStyles
        )
        #expect(await waitUntil { didFinishLoad })

        let metrics = try await evaluateString(
            """
            (function() {
              function measure() {
                var item = document.querySelector('li.task');
                var check = item.querySelector('.task-check').getBoundingClientRect();
                var content = item.querySelector('.task-content');
                var walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT);
                var textNode = walker.nextNode();
                var range = document.createRange();
                range.selectNodeContents(textNode);
                var firstLine = range.getClientRects()[0];
                var centerDelta = (check.top + check.height / 2) -
                                  (firstLine.top + firstLine.height / 2);
                return getComputedStyle(item).display + '|' + centerDelta.toFixed(2) + '|' +
                       check.height.toFixed(2) + '|' + firstLine.height.toFixed(2) + '|' +
                       parseFloat(getComputedStyle(item).fontSize).toFixed(2);
              }
              var normal = measure();
              document.documentElement.style.setProperty('--body-size', '32px');
              return normal + ';' + measure();
            })()
            """,
            in: webView
        )
        let samples = metrics.split(separator: ";")
        #expect(samples.count == 2)
        for sample in samples {
            let fields = sample.split(separator: "|")
            #expect(fields.count == 5)
            #expect(fields.first == "grid")
            let delta = Double(fields[1]) ?? 100
            let fontSize = Double(fields[4]) ?? 1
            #expect(abs(delta / fontSize) <= 0.08)
        }
    }

    @Test("loaded heading and block-ID links reach the delegate and scroll the DOM")
    func loadedWikiLinkActivation() async throws {
        let firstFiller = (1...20).map { "First paragraph \($0)." }.joined(separator: "\n\n")
        let secondFiller = (1...20).map { "Second paragraph \($0)." }.joined(separator: "\n\n")
        let markdown = "[[#Far]] [[#^block-target]]\n\n\(firstFiller)\n\n" +
            "## Far\nHeading target\n\n\(secondFiller)\n\nBlock target ^block-target"
        let editor = makeEditor()
        editor.loadContent(markdown)

        let webView = ReadModeWebView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 280),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView

        var didFinishLoad = false
        var activatedTargets: [String] = []
        webView.onLoadFinished = { didFinishLoad = true }
        webView.onOpenWikiLink = { target in
            activatedTargets.append(target)
            if let line = editor.sourceLine(forPageLocalWikiTarget: target) {
                webView.setScrollPosition(line: line, fraction: 0)
            }
        }
        webView.render(
            markdown: markdown,
            theme: .default,
            callouts: Callout.defaultStyles
        )

        #expect(await waitUntil { didFinishLoad })
        _ = try await webView.evaluateJavaScript(
            "document.querySelectorAll('a.wikilink')[0].click()"
        )
        #expect(await waitUntil { activatedTargets.count == 1 })
        let headingScroll = try #require(await scrollTop(of: webView, greaterThan: 100))

        _ = try await webView.evaluateJavaScript(
            "document.querySelectorAll('a.wikilink')[1].click()"
        )
        #expect(await waitUntil { activatedTargets.count == 2 })
        let blockScroll = try #require(await scrollTop(of: webView, greaterThan: headingScroll))
        #expect(activatedTargets == ["#Far", "#^block-target"])
        #expect(blockScroll > headingScroll)

        let cursor = try await webView.evaluateJavaScript(
            "getComputedStyle(document.querySelector('a.wikilink')).cursor"
        ) as? String
        #expect(cursor == "pointer")
    }

    private func scrollTop(of webView: WKWebView, greaterThan minimum: Double) async -> Double? {
        var observed: Double?
        let reachedTarget = await waitUntil {
            observed = try? await webView.evaluateJavaScript(
                "document.scrollingElement.scrollTop"
            ) as? Double
            return observed.map { $0 > minimum } ?? false
        }
        return reachedTarget ? observed : nil
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }
}
