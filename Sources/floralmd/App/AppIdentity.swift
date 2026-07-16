import Foundation

/// Build identity that must stay aligned with the selected bundle plist.
/// Production is selected only by the release build entry point; every ordinary
/// SwiftPM build uses the isolated Debug identity.
enum AppIdentity {
    #if FLORALMD_PRODUCTION
    static let fallbackDisplayName = "FloralMD"
    static let logDirectoryComponent = ".floralmd/logs"
    #else
    static let fallbackDisplayName = "FloralMD-Debug"
    static let logDirectoryComponent = ".floralmd-debug/logs"
    #endif

    static var displayName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? fallbackDisplayName
    }
}
