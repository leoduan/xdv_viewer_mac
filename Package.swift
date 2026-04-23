// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XDVNativeViewer",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "xdv-native-viewer", targets: ["XDVNativeViewer"]),
    ],
    targets: [
        .executableTarget(
            name: "XDVNativeViewer",
            path: "Sources"
        ),
    ]
)
