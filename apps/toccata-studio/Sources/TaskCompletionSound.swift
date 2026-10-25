import AppKit

@MainActor
enum TaskCompletionSound {
    // Keep one player alive, with a restrained level relative to other app audio.
    private static let sound: NSSound? = {
        guard let url = AppResources.bundle.url(forResource: "task-completed", withExtension: "wav"),
              let sound = NSSound(contentsOf: url, byReference: false) else { return nil }
        sound.volume = 0.6
        return sound
    }()

    static func play() {
        // A quick run of completions should not layer or cut off the chime's tail.
        guard let sound, !sound.isPlaying else { return }
        sound.play()
    }
}
