import AVFoundation
import UIKit

/// Turn cues from the "Turn cues" board: taps you can feel, tones and a voice you can hear in your ears.
///
/// Left: two taps, low tone. Right: three taps, high tone. Straight on: nothing.
/// Off the loop: one long buzz. Running late: a tap, then a buzz.
/// Each tone can be followed by a spoken line, so a walk works with the phone locked in a pocket,
/// where iOS may not deliver the taps.
final class CuePlayer: NSObject, AVSpeechSynthesizerDelegate {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private let voice = AVSpeechSynthesizer()
    /// Tones and lines still playing. The audio session is released when this reaches zero.
    private var pending = 0

    override init() {
        super.init()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        voice.usesApplicationAudioSession = true
        voice.delegate = self
    }

    /// With `wristTaps`, the watch is tapping the wrist, so the phone in a pocket does not tap as well.
    func play(_ cue: WatchMessage.Cue, say line: String? = nil, wristTaps: Bool = false) {
        switch cue {
        case .left:
            if !wristTaps { taps(2) }
            tone(frequency: 440, beeps: 2, then: line)
        case .right:
            if !wristTaps { taps(3) }
            tone(frequency: 880, beeps: 3, then: line)
        case .offLoop:
            if !wristTaps { buzz(after: 0) }
            tone(frequency: 330, beeps: 1, length: 0.6, then: line)
        case .late:
            if !wristTaps {
                taps(1)
                buzz(after: 0.25)
            }
            tone(frequency: 660, beeps: 2, length: 0.12, then: line)
        }
    }

    /// A spoken line on its own, with no tone or taps.
    func say(_ line: String) {
        guard activate() else { return }
        speak(line)
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

    // MARK: Audio session

    /// Plays over whatever else is playing, ducking it briefly.
    private func activate() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .voicePrompt, options: [.mixWithOthers, .duckOthers])
            try session.setActive(true)
            return true
        } catch {
            return false
        }
    }

    private func finishedOne() {
        pending = max(0, pending - 1)
        guard pending == 0 else { return }
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Tones

    /// Plays short sine beeps, then speaks `line` if there is one.
    private func tone(frequency: Double, beeps: Int, length: TimeInterval = 0.09, then line: String?) {
        guard activate() else { return }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            if let line { speak(line) }
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
        pending += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if let line { self.speak(line) }
                self.finishedOne()
            }
        }
        player.play()
    }

    // MARK: Voice

    private func speak(_ line: String) {
        pending += 1
        let utterance = AVSpeechUtterance(string: line)
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        voice.speak(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.finishedOne() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.finishedOne() }
    }
}
