import AppKit

/// Tiny tactile + audio feedback for the conversion flow. Haptics use the
/// trackpad's `NSHapticFeedbackManager`; sounds use built-in system `.aiff`
/// files (no bundled assets). All effects are quiet, optional, and never block.
enum Feedback {

    /// A trackpad haptic tap. `.levelChange` is the soft "alignment" tick;
    /// `.generic` is a single bump. Silently no-ops on hardware without haptics.
    static func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .levelChange) {
        NSHapticFeedbackManager.defaultPerformer
            .perform(pattern, performanceTime: .now)
    }

    /// A short system sound by name. Missing names are ignored.
    static func sound(_ name: String, volume: Float = 0.35) {
        // NSSound(named:) returns a shared cached instance; replaying while it's
        // still playing logs "Already playing". Copy so rapid events overlap cleanly.
        guard let s = (NSSound(named: name)?.copy() as? NSSound) else { return }
        s.volume = volume
        s.play()
    }

    // MARK: - Semantic events

    /// One conversion step advanced — a soft "pop" (not the flat "Tink" that
    /// reads like a dead key press).
    static func step() {
        haptic(.levelChange)
        sound("Pop", volume: 0.22)
    }

    /// Conversion finished successfully — a satisfying landing.
    static func success() {
        haptic(.generic)
        sound("Glass", volume: 0.4)
    }

    /// Conversion failed — a soft, low error note (not the harsh "Basso" thunk).
    static func failure() {
        haptic(.generic)
        sound("Submarine", volume: 0.4)
    }
}
