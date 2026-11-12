import AppKit

/// Subtle, rate-limited feedback on supported Force Touch trackpads.
@MainActor enum InteractionFeedback {
    private static var lastSelection: TimeInterval = 0
    static func selection() {
        guard UserDefaults.standard.object(forKey: "moriq.hapticsEnabled") as? Bool ?? true else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSelection >= 0.07 else { return }
        lastSelection = now
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
    static func confirmation() {
        guard UserDefaults.standard.object(forKey: "moriq.hapticsEnabled") as? Bool ?? true else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }
}

@MainActor enum InteractionArbiter {
    static var selectingScreenshot = false
    static var systemScreenshotActive: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.screencaptureui").contains { !$0.isTerminated }
    }
    static var screenshotActive: Bool { selectingScreenshot || systemScreenshotActive }
}

enum ConversionTrigger {
    static func isHeld(_ flags: NSEvent.ModifierFlags, preference: String) -> Bool {
        let relevant = flags.intersection([.shift, .option, .control, .command])
        switch preference {
        case "option": return relevant == .option
        case "control": return relevant == .control
        default: return relevant == .shift
        }
    }
    static func isHeld(_ flags: NSEvent.ModifierFlags) -> Bool {
        isHeld(flags, preference: UserDefaults.standard.string(forKey: "moriq.converterModifier") ?? "shift")
    }
}
