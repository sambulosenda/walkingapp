import AVFoundation
import UIKit

/// Turn cues from the "Turn cues" board: taps you can feel, tones you can hear in your ears.
///
/// Left: two taps, low tone. Right: three taps, high tone. Straight on: nothing.
/// Off the loop: one long buzz. Running late: a tap, then a buzz.
final class CuePlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var started = false

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func play(_ cue: WatchMessage.Cue) {
        switch cue {
        case .left:
            taps(2)
            tone(frequency: 440, beeps: 2)
        case .right:
            taps(3)
            tone(frequency: 880, beeps: 3)
        case .offLoop:
            buzz(after: 0)
            tone(frequency: 330, beeps: 1, length: 0.6)
        case .late:
            taps(1)
            buzz(after: 0.25)
            tone(frequency: 660, beeps: 2, length: 0.12)
        }
    }

    // MARK: Haptics

    private func taps(_ count: Int) {
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.prepare()
        for i in 0..<count {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.18) { generator.impactOccurred() }
        }
    }

    private func buzz(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.warning)
        }
    }

    // MARK: Tones

    /// Plays short sine beeps over whatever else is playing, ducking it briefly.
    private func tone(frequency: Double, beeps: Int, length: TimeInterval = 0.09) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers, .duckOthers])
            try session.setActive(true)
            if !started { try engine.start(); started = true }
        } catch {
            return
        }
        let rate = format.sampleRate
        let gap = 0.09
        let total = Double(beeps) * (length + gap)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total * rate)) else { return }
        buffer.frameLength = buffer.frameCapacity
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(buffer.frameLength) {
            let t = Double(i) / rate
            let inBeep = t.truncatingRemainder(dividingBy: length + gap)
            if inBeep < length {
                // Short fade in and out so the beep doesn't click.
                let envelope = min(1, inBeep / 0.01, (length - inBeep) / 0.01)
                samples[i] = Float(sin(2 * .pi * frequency * t) * 0.35 * envelope)
            } else {
                samples[i] = 0
            }
        }
        player.scheduleBuffer(buffer) {
            DispatchQueue.main.async {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
        player.play()
    }
}
