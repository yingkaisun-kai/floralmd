import AppKit
import FloralMDCore
@preconcurrency import QuickLookUI
import UniformTypeIdentifiers

/// Finder Quick Look provider backed by FloralMD's existing read-mode renderer.
/// The returned HTML is self-contained: local images are inlined and equations
/// remain readable source, so Quick Look needs no follow-up file access.
@MainActor
final class PreviewProvider: QLPreviewProvider, @preconcurrency QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest,
                        completionHandler handler: @escaping (QLPreviewReply?, Error?) -> Void) {
        do {
            let markdown = try String(contentsOf: request.fileURL, encoding: .utf8)
            // A data-based Quick Look reply is immutable after generation, and
            // its HTML host does not reliably honor prefers-color-scheme. Resolve
            // AppKit's current appearance for each newly opened preview instead.
            let dark = AppearanceResolver.isDark(NSApplication.shared.effectiveAppearance)
            let html = DocumentHTML.full(
                markdown: markdown,
                theme: .default,
                callouts: Callout.defaultStyles,
                dark: dark,
                baseURL: request.fileURL.deletingLastPathComponent(),
                options: ReadRenderOptions(preserveBlankLines: true,
                                           allowRemoteImages: false,
                                           maxContentWidthPoints: 760),
                renderMath: false
            )
            let data = Data(html.utf8)
            let reply = QLPreviewReply(
                dataOfContentType: .html,
                contentSize: NSSize(width: 900, height: 700)
            ) { _ in data }
            reply.title = request.fileURL.lastPathComponent
            handler(reply, nil)
        } catch {
            handler(nil, error)
        }
    }
}
