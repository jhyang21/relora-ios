// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ReloraKit",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "ReloraCore", targets: ["ReloraCore"]),
        .library(name: "ReloraData", targets: ["ReloraData"]),
        .library(name: "ReloraSync", targets: ["ReloraSync"]),
        .library(name: "ReloraServices", targets: ["ReloraServices"]),
        .library(name: "ReloraDesign", targets: ["ReloraDesign"]),
        .library(name: "ReloraFeatures", targets: ["ReloraFeatures"])
    ],
    dependencies: [
        // Pinned exact: the generated xcodeproj resolves dependencies through
        // its own gitignored workspace file, so these pins are the only
        // version lock CI honors. Bump deliberately, never by drift.
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/supabase/supabase-swift.git", exact: "2.55.1"),
        .package(url: "https://github.com/RevenueCat/purchases-ios-spm.git", exact: "5.87.1")
    ],
    targets: [
        .target(
            name: "ReloraCore"
        ),
        .target(
            name: "ReloraData",
            dependencies: [
                "ReloraCore",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .target(
            name: "ReloraSync",
            dependencies: [
                "ReloraCore",
                "ReloraData"
            ]
        ),
        .target(
            name: "ReloraServices",
            dependencies: [
                "ReloraCore",
                "ReloraData",
                .product(name: "Auth", package: "supabase-swift"),
                .product(name: "RevenueCat", package: "purchases-ios-spm")
            ]
        ),
        .target(
            name: "ReloraDesign",
            dependencies: [
                "ReloraCore"
            ],
            // Token reference doc, kept beside the tokens it describes.
            // Excluded so SwiftPM does not treat it as an unhandled resource.
            exclude: ["DesignDoc.md"]
        ),
        .target(
            name: "ReloraFeatures",
            dependencies: [
                "ReloraCore",
                "ReloraData",
                "ReloraSync",
                "ReloraServices",
                "ReloraDesign"
            ]
        ),
        .testTarget(
            name: "ReloraCoreTests",
            dependencies: ["ReloraCore"]
        ),
        .testTarget(
            name: "ReloraDataTests",
            dependencies: ["ReloraData"]
        ),
        .testTarget(
            name: "ReloraSyncTests",
            dependencies: ["ReloraSync", "ReloraData", "ReloraCore"]
        ),
        .testTarget(
            name: "ReloraServicesTests",
            dependencies: ["ReloraServices", "ReloraCore"]
        ),
        .testTarget(
            name: "ReloraDesignTests",
            dependencies: ["ReloraDesign"]
        ),
        .testTarget(
            name: "ReloraFeaturesTests",
            dependencies: ["ReloraFeatures", "ReloraCore", "ReloraData", "ReloraServices", "ReloraSync"]
        )
    ]
)
