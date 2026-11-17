import AVFoundation

/// Spoken directions using the on-device speech synthesiser (works with no network).
final class VoiceGuide {
    var enabled = true
    private let synth = AVSpeechSynthesizer()
    private var sessionReady = false

    func say(_ text: String) {
        guard enabled else { return }
        if !sessionReady {
            let audio = AVAudioSession.sharedInstance()
            try? audio.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .mixWithOthers])
            sessionReady = true
        }
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(utterance)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
    }
}
