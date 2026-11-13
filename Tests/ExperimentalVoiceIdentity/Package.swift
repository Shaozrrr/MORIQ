// swift-tools-version: 6.0
import Foundation
import PackageDescription
let path = ProcessInfo.processInfo.environment["MORIQ_FLUIDAUDIO_SOURCE"] ?? "/tmp/moriq-fluidaudio-research"
let package = Package(name: "VoiceIdentityCheck", platforms: [.macOS(.v15)], dependencies: [.package(name: "FluidAudioSource", path: path)], targets: [.executableTarget(name: "VoiceIdentityCheck", dependencies: [.product(name: "FluidAudio", package: "FluidAudioSource")])])
