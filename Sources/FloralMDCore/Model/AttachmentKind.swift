import Foundation

/// The semantic category of a non-image `![[target]]` attachment label.
///
/// FloralMD does not preview these files. The category only gives the existing
/// source-backed label a clearer visual and accessible description.
public enum AttachmentKind: String, CaseIterable, Equatable, Sendable {
    case pdf
    case audio
    case video
    case note
    case unknown

    private static let audioExtensions: Set<String> = [
        "3gp", "aac", "flac", "m4a", "mp3", "oga", "ogg", "opus", "wav", "weba",
    ]
    private static let videoExtensions: Set<String> = [
        "avi", "m4v", "mkv", "mov", "mp4", "ogv", "webm",
    ]
    private static let noteExtensions: Set<String> = ["md", "markdown", "mdx"]

    public static func classify(target: String) -> AttachmentKind {
        let path = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? target
        let decoded = path.removingPercentEncoding ?? path
        let ext = (decoded as NSString).pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if audioExtensions.contains(ext) { return .audio }
        if videoExtensions.contains(ext) { return .video }
        if ext.isEmpty || noteExtensions.contains(ext) { return .note }
        return .unknown
    }

    /// Short, bilingual copy used by Read mode's visible category marker.
    public var bilingualLabel: String {
        switch self {
        case .pdf: return "PDF"
        case .audio: return "Audio / 音频"
        case .video: return "Video / 视频"
        case .note: return "Note / 笔记"
        case .unknown: return "File / 附件"
        }
    }

    /// Bilingual assistive copy shared by Edit tooltips and Read HTML.
    public func accessibilityLabel(target: String) -> String {
        let nouns: (String, String)
        switch self {
        case .pdf: nouns = ("PDF attachment", "PDF 附件")
        case .audio: nouns = ("Audio attachment", "音频附件")
        case .video: nouns = ("Video attachment", "视频附件")
        case .note: nouns = ("Markdown note attachment", "Markdown 笔记附件")
        case .unknown: nouns = ("Unknown attachment", "未知附件")
        }
        return "\(nouns.0) / \(nouns.1); preview unavailable / 暂不支持预览: \(target)"
    }
}
