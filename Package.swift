// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DakPush",
    platforms: [.iOS(.v15)],
    products: [
        // The app's SDK.
        .library(name: "DakPush", targets: ["DakPush"]),
        // For the app's notification service extension: images, buttons,
        // delivery receipts. Safe for app extensions.
        .library(name: "DakPushExtension", targets: ["DakPushExtension"]),
    ],
    targets: [
        .target(
            name: "DakPush",
            dependencies: ["DakPushExtension"],
            resources: [.process("PrivacyInfo.xcprivacy")]
        ),
        .target(
            name: "DakPushExtension",
            resources: [.process("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "DakPushTests",
            dependencies: ["DakPush"]
        ),
        .testTarget(
            name: "DakPushExtensionTests",
            dependencies: ["DakPushExtension"]
        ),
    ]
)
