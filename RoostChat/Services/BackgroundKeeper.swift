import AVFoundation
import Foundation

/// Optional and off by default. Keeps the app running in the background so the
/// connection, and therefore the chosen status and notifications, survive leaving
/// the screen.
///
/// iOS suspends ordinary apps within seconds, and a chat app has no sanctioned way
/// to stay connected without push. This plays silence through the audio background
/// mode, mixed with other audio so it doesn't interrupt music. It costs battery,
/// and iOS can still end the app. App Review may also reject it, so it would need
/// revisiting before any notarized release.
final class BackgroundKeeper {
    private var player: AVAudioPlayer?
    private var wantsRunning = false
    private var observer: NSObjectProtocol?

    var isRunning: Bool { player?.isPlaying == true }

    init() {
        observer = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            self?.handleInterruption(note)
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func start() {
        wantsRunning = true
        guard !isRunning else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(data: Self.silentWAV(), fileTypeHint: AVFileType.wav.rawValue)
            player.numberOfLoops = -1
            player.prepareToPlay()
            guard player.play() else {
                DebugLog.shared.add(.app, "Background keep-alive: playback did not start")
                return
            }
            self.player = player
            DebugLog.shared.add(.app, "Background keep-alive started")
        } catch {
            DebugLog.shared.add(.app, "Background keep-alive failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        wantsRunning = false
        guard player != nil else { return }
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        DebugLog.shared.add(.app, "Background keep-alive stopped")
    }

    /// Calls and alarms stop the audio session, and iOS may suspend the app until
    /// it resumes.
    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        DebugLog.shared.add(.app, "Audio interruption: \(type == .began ? "began" : "ended")")
        if type == .ended, wantsRunning {
            player = nil
            start()
        }
    }

    /// One second of silence as an in-memory 8 kHz, 16-bit mono WAV file.
    private static func silentWAV() -> Data {
        let sampleRate: UInt32 = 8000
        let byteCount = sampleRate * 2
        var data = Data()
        func append(_ text: String) { data.append(contentsOf: text.utf8) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append("RIFF")
        append32(36 + byteCount)
        append("WAVEfmt ")
        append32(16)
        append16(1)
        append16(1)
        append32(sampleRate)
        append32(sampleRate * 2)
        append16(2)
        append16(16)
        append("data")
        append32(byteCount)
        data.append(Data(count: Int(byteCount)))
        return data
    }
}
