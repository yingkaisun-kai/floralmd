// swift-tools-version: 6.0
// Modified from Edmund by Yingkai Sun for FloralMD.
import Foundation
import PackageDescription

// Local builds are Debug by default and deliberately exclude Sparkle.  The
// release workflow must opt into the production graph explicitly so a normal
// `swift build` cannot acquire the production updater identity by accident.
let isProductionBuild = ProcessInfo.processInfo.environment["FLORALMD_BUILD_VARIANT"] == "production"

let packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.5.0"),
    .package(url: "https://github.com/mgriebling/SwiftMath.git", from: "1.7.0"),
    // Keep the pin stable in Package.resolved across variants. Only the
    // production app target below depends on the Sparkle product, so Debug
    // neither links nor embeds the framework.
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
]
var appDependencies: [Target.Dependency] = ["FloralMDCore"]
if isProductionBuild {
    appDependencies.append(.product(name: "Sparkle", package: "Sparkle"))
}

let package = Package(
    name: "FloralMD",
    platforms: [.macOS(.v14)],
    dependencies: packageDependencies,
    targets: [
        .target(
            name: "FloralMDCore",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "SwiftMath", package: "SwiftMath"),
            ],
            swiftSettings: isProductionBuild ? [.define("FLORALMD_PRODUCTION")] : []),
        // The user-facing app is "FloralMD" (CFBundleName); the executable target
        // and Mach-O binary use the matching lowercase name `floralmd`.
        .executableTarget(
            name: "floralmd",
            dependencies: appDependencies,
            swiftSettings: isProductionBuild ? [.define("FLORALMD_PRODUCTION")] : []),
        // Built as an extension executable (`NSExtensionMain` is the entry
        // point) and assembled into FloralMD.app by scripts/build-app.sh.
        .executableTarget(
            name: "FloralMDQuickLook",
            dependencies: ["FloralMDCore"],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"]),
            ]),
        .testTarget(
            name: "FloralMDTests",
            dependencies: ["FloralMDCore"]),
    ]
)
