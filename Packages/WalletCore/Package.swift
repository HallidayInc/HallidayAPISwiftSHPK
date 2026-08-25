// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WalletCore",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "WalletCore", targets: ["WalletCore", "WalletCoreSwiftProtobuf"])
    ],
    targets: [
        .binaryTarget(
            name: "WalletCore",
            url: "https://github.com/trustwallet/wallet-core/releases/download/4.7.2/WalletCore.xcframework.zip",
            checksum: "26f0a49e1200d95cd7e79e50f9a38c4374b96bfacf8c16bc175e6d9485baa215"
        ),
        .binaryTarget(
            name: "WalletCoreSwiftProtobuf",
            url: "https://github.com/trustwallet/wallet-core/releases/download/4.7.2/WalletCoreSwiftProtobuf.xcframework.zip",
            checksum: "2b486c46e2ceecacc125bd643d9c5f6c331ba98df6cb6140e625b4f840a4aa48"
        ),
    ]
)
