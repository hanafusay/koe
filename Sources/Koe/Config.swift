import Foundation
import ServiceManagement

final class Config: ObservableObject {
    static let shared = Config()

    /// 音声認識は日本語に固定する。
    static let recognitionLanguage = "ja-JP"

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let audioInputDeviceUID = "audioInputDeviceUID"
        static let triggerKey = "triggerKey"
        static let dictionary = "dictionary"
        static let history = "history"
        static let soundEffects = "soundEffects"
    }

    @Published var soundEffects: Bool {
        didSet { defaults.set(soundEffects, forKey: Keys.soundEffects) }
    }

    static let historyLimit = 10

    /// 入力した文。新しいものが先頭。
    @Published private(set) var history: [String] {
        didSet { defaults.set(history, forKey: Keys.history) }
    }

    func remember(_ text: String) {
        history = Array(([text] + history).prefix(Self.historyLimit))
    }

    func clearHistory() {
        history = []
    }

    @Published var dictionary: [DictionaryEntry] {
        didSet { defaults.set(try? JSONEncoder().encode(dictionary), forKey: Keys.dictionary) }
    }

    @Published var audioInputDeviceUID: String {
        didSet { defaults.set(audioInputDeviceUID, forKey: Keys.audioInputDeviceUID) }
    }

    @Published var triggerKey: TriggerKey {
        didSet { defaults.set(triggerKey.rawValue, forKey: Keys.triggerKey) }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                Log.d("[Config] Failed to \(launchAtLogin ? "register" : "unregister") launch at login: \(error)")
                // Revert to actual state on failure
                let actual = SMAppService.mainApp.status == .enabled
                if actual != launchAtLogin {
                    launchAtLogin = actual
                }
            }
        }
    }

    private init() {
        self.launchAtLogin = SMAppService.mainApp.status == .enabled

        self.audioInputDeviceUID = defaults.string(forKey: Keys.audioInputDeviceUID) ?? ""

        self.dictionary = defaults.data(forKey: Keys.dictionary)
            .flatMap { try? JSONDecoder().decode([DictionaryEntry].self, from: $0) } ?? []

        self.history = defaults.stringArray(forKey: Keys.history) ?? []

        self.soundEffects = defaults.object(forKey: Keys.soundEffects) as? Bool ?? true

        if let savedTriggerKey = defaults.string(forKey: Keys.triggerKey),
           let key = TriggerKey(rawValue: savedTriggerKey) {
            self.triggerKey = key
        } else {
            self.triggerKey = .fn
        }
    }
}
