import AVFoundation
import AppKit

/// Preloaded WAV players with near-zero latency.
/// Volume default 0.12 (matches prototype: gain ×6 then vol=0.12).
@MainActor
final class SoundEngine {
    static let shared = SoundEngine()

    var enabled: Bool = true
    var volume: Float = 0.12 {
        didSet { players.values.forEach { $0.forEach { $0.volume = volume } } }
    }

    // Pool of 3 players per sound to allow overlapping playback
    private var players: [String: [AVAudioPlayer]] = [:]

    private init() {
        preload()
    }

    private func preload() {
        let names = ["peek","open","close","hover","blip","slap","annoyed","dizzy","greet",
                     "work","finish","error","approval","question","approve","gulp","tick",
                     "send","love","pop","proud","wink","yawn","attach","think","search",
                     "rate","sleep","greeting"]
        for name in names {
            guard let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "sounds") else { continue }
            var pool: [AVAudioPlayer] = []
            for _ in 0..<3 {
                if let p = try? AVAudioPlayer(contentsOf: url) {
                    p.volume = volume
                    p.prepareToPlay()
                    pool.append(p)
                }
            }
            if !pool.isEmpty { players[name] = pool }
        }
    }

    /// Fade out all currently-playing instances of `name` over `duration` seconds,
    /// then stop and reset them so they can be reused.
    func fadeOut(_ name: String, duration: TimeInterval) {
        guard let pool = players[name] else { return }
        for player in pool where player.isPlaying {
            player.setVolume(0, fadeDuration: duration)
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak player] in
                guard let p = player else { return }
                p.stop()
                p.currentTime = 0
                p.volume = self.volume
            }
        }
    }

    func play(_ name: String) {
        guard enabled && AppState.shared.soundEnabled else { return }
        guard let pool = players[name] else { return }
        // Find a player that is not currently playing
        let player = pool.first { !$0.isPlaying } ?? pool[0]
        // play() can block for ~150 ms on the first call; keep it off the main thread so a click does not stall the UI.
        let job = PlayJob(player: player, volume: volume)
        Self.queue.async {
            job.player.currentTime = 0
            job.player.volume = job.volume
            job.player.play()
        }
    }

    private static let queue = DispatchQueue(label: "coucou.sound", qos: .userInitiated)

    private struct PlayJob: @unchecked Sendable {
        let player: AVAudioPlayer
        let volume: Float
    }
}
