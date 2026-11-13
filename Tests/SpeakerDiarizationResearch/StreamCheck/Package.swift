// swift-tools-version: 6.0
import Foundation
import PackageDescription
let path = ProcessInfo.processInfo.environment["MORIQ_FLUIDAUDIO_SOURCE"] ?? "/tmp/fluidaudio"
let package = Package(name:"StreamCheck", platforms:[.macOS(.v14)], dependencies:[.package(name:"FluidAudioSource",path:path)], targets:[.executableTarget(name:"StreamCheck",dependencies:[.product(name:"FluidAudio",package:"FluidAudioSource")])])
