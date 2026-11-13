// swift-tools-version: 6.0
import Foundation
import PackageDescription
let source = ProcessInfo.processInfo.environment["MORIQ_FLUIDAUDIO_SOURCE"] ?? "/tmp/moriq-fluidaudio-research"
let package = Package(name:"VoiceProbe", platforms:[.macOS(.v14)], dependencies:[.package(name:"FluidAudioSource",path:source)], targets:[.executableTarget(name:"VoiceProbe",dependencies:[.product(name:"FluidAudio",package:"FluidAudioSource")])])
