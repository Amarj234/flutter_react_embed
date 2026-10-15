// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "flutter_react_embed_ios",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "flutter-react-embed-ios", targets: ["flutter_react_embed_ios"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "flutter_react_embed_ios",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
