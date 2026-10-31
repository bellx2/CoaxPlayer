// swift-tools-version: 6.0
import PackageDescription

// scripts/build-deps.sh で作った libmpv と libaribcaption。Homebrew のものは使わない
let deps = Context.packageDirectory + "/.deps/prefix"

let package = Package(
    name: "CoaxPlayer",
    platforms: [.macOS(.v13)],
    targets: [
        .systemLibrary(
            name: "CMpv",
            path: "Sources/CMpv"
        ),
        .systemLibrary(
            name: "CAribCaption",
            path: "Sources/CAribCaption"
        ),
        .executableTarget(
            name: "CoaxPlayer",
            dependencies: ["CMpv", "CAribCaption"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-Xcc", "-I\(deps)/include"]),
            ],
            linkerSettings: [
                // .app では Contents/Frameworks から、swift run では .deps から読む
                .unsafeFlags([
                    "-L\(deps)/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "\(deps)/lib",
                ]),
            ]
        ),
    ]
)
