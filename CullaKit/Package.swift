// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CullaKit",
    // Text is in English in the source and translated in each target's Localizable.xcstrings
    // (docs/localization.md). `Scripts/l10n.py` checks, exports and imports the translations.
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CullaCore", targets: ["CullaCore"]),
        .library(name: "CullaFiles", targets: ["CullaFiles"]),
        .library(name: "CullaAnalysis", targets: ["CullaAnalysis"]),
        .library(name: "CullaSession", targets: ["CullaSession"]),
        .library(name: "CullaStore", targets: ["CullaStore"]),
        .library(name: "CullaCommands", targets: ["CullaCommands"]),
        .library(name: "CullaPipeline", targets: ["CullaPipeline"]),
        .executable(name: "culla-eval", targets: ["culla-eval"]),
    ],
    dependencies: [
        // The only third-party package. Only CullaStore links it; culla-eval does not.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(name: "CullaCore", resources: [.process("Localizable.xcstrings")]),
        .target(name: "CullaFiles", dependencies: ["CullaCore"], resources: [.process("Localizable.xcstrings")]),
        .target(name: "CullaAnalysis", dependencies: ["CullaCore"]),
        .target(
            name: "CullaSession", dependencies: ["CullaCore", "CullaAnalysis"], resources: [.process("Localizable.xcstrings")]
        ),
        .target(
            name: "CullaStore",
            dependencies: ["CullaCore", "CullaSession", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        // Commands, key bindings and selection logic for the app's interface. No AppKit.
        .target(name: "CullaCommands", dependencies: ["CullaSession"], resources: [.process("Localizable.xcstrings")]),
        // Background analysis of an open shoot: scheduler, score cache, grouping and best picks.
        .target(
            name: "CullaPipeline",
            dependencies: ["CullaCore", "CullaFiles", "CullaAnalysis", "CullaSession", "CullaStore"],
            resources: [.process("Localizable.xcstrings")]
        ),
        // Measures CullaPipeline on a real folder. A development tool; not part of the app.
        .executableTarget(
            name: "culla-pipeline-bench",
            dependencies: ["CullaCore", "CullaFiles", "CullaSession", "CullaStore", "CullaPipeline"]
        ),
        .executableTarget(
            name: "culla-eval",
            dependencies: ["CullaCore", "CullaFiles", "CullaAnalysis"]
        ),
        // LocalizationFixture.xcstrings is test data: made-up Russian and Turkmen for the plural tests.
        .testTarget(name: "CullaCoreTests", dependencies: ["CullaCore"], resources: [.process("LocalizationFixture.xcstrings")]),
        .testTarget(name: "CullaFilesTests", dependencies: ["CullaFiles"]),
        .testTarget(name: "CullaAnalysisTests", dependencies: ["CullaAnalysis"]),
        .testTarget(name: "CullaSessionTests", dependencies: ["CullaSession"]),
        .testTarget(name: "CullaStoreTests", dependencies: ["CullaStore"]),
        .testTarget(name: "CullaCommandsTests", dependencies: ["CullaCommands", "CullaSession"]),
        // Applying decisions to disk and undoing it, end to end: plan, executor, journal, session.
        .testTarget(
            name: "CullaApplyTests",
            dependencies: ["CullaCore", "CullaFiles", "CullaSession", "CullaStore", "CullaPipeline"]
        ),
        .testTarget(
            name: "CullaPipelineTests",
            dependencies: ["CullaCore", "CullaFiles", "CullaAnalysis", "CullaSession", "CullaStore", "CullaPipeline"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
