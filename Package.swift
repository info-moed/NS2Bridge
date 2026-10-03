// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NS2Bridge",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NS2Kit", targets: ["NS2Kit"]),
        .executable(name: "ns2probe", targets: ["ns2probe"]),
        .executable(name: "NS2Bridge", targets: ["NS2BridgeApp"]),
    ],
    targets: [
        .target(
            name: "NS2Kit",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("IOUSBHost"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreBluetooth"),
            ]
        ),
        .executableTarget(
            name: "ns2probe",
            dependencies: ["NS2Kit"],
            linkerSettings: [.linkedFramework("GameController")]
        ),
        .executableTarget(
            name: "NS2BridgeApp",
            dependencies: ["NS2Kit"],
            linkerSettings: [.linkedFramework("ServiceManagement"), .linkedFramework("UserNotifications")]
        ),
        .testTarget(name: "NS2KitTests", dependencies: ["NS2Kit"]),
    ],
    swiftLanguageModes: [.v5]
)
