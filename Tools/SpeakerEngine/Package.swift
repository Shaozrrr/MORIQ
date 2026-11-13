// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Exact upstream revision used by the isolated experiments. The local override
// exists only for repeatable development and CI; no sources are vendored here.
let dependency: Package.Dependency = {
    if let path = ProcessInfo.processInfo.environment["MORIQ_FLUIDAUDIO_SOURCE"] {
        return .package(name: "FluidAudioSource", path: path)
    }
    return .package(name: "FluidAudioSource", url: "https://github.com/FluidInference/FluidAudio.git", revision: "d653a34a620c013febd7530427b4963ae18064b2")
}()
let package = Package(name: "MORIQSpeakerEngine", platforms: [.macOS(.v15)], dependencies: [dependency], targets: [
    .executableTarget(name: "MORIQSpeakerEngine", dependencies: [.product(name: "FluidAudio", package: "FluidAudioSource")])
])
