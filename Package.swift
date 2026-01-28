// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UboSwift",
    platforms: [
        .iOS(.v18),
        .watchOS(.v11),
        .macOS(.v15),
        .tvOS(.v18),
        .visionOS(.v2)
    ],
    products: [
        .library(
            name: "UboSwift",
            targets: ["UboSwift"]
        ),
        .executable(
            name: "ubo-test",
            targets: ["UboTest"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "1.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
    ],
    targets: [
        .target(
            name: "UboSwift",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .executableTarget(
            name: "UboTest",
            dependencies: ["UboSwift"]
        ),
        .testTarget(
            name: "UboSwiftTests",
            dependencies: ["UboSwift"]
        ),
    ]
)
