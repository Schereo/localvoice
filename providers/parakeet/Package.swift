// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LocalVoiceParakeet",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "localvoice-parakeet", targets: ["ParakeetWorker"])],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.18.4",
            traits: []
        ),
    ],
    targets: [
        .executableTarget(
            name: "ParakeetWorker",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
    ]
)
