// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DetectiveGadget",
    products: [
        .executable(name: "detective-gadget", targets: ["DetectiveGadget"])
    ],
    targets: [
        .executableTarget(name: "DetectiveGadget"),
        .testTarget(name: "DetectiveGadgetTests", dependencies: ["DetectiveGadget"])
    ]
)
