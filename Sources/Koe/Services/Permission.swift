import AVFoundation
import Cocoa
import Speech

enum Permission: CaseIterable, Identifiable {
    case microphone
    case speechRecognition
    case accessibility
    case inputMonitoring

    var id: Self { self }

    var title: String {
        switch self {
        case .microphone: return "マイク"
        case .speechRecognition: return "音声認識"
        case .accessibility: return "アクセシビリティ"
        case .inputMonitoring: return "入力監視"
        }
    }

    var purpose: String {
        switch self {
        case .microphone: return "録音"
        case .speechRecognition: return "文字起こし"
        case .accessibility: return "キー操作の検知と貼り付け"
        case .inputMonitoring: return "録音キーの検知"
        }
    }

    var isGranted: Bool {
        switch self {
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .speechRecognition: return SFSpeechRecognizer.authorizationStatus() == .authorized
        case .accessibility: return AXIsProcessTrusted()
        case .inputMonitoring: return CGPreflightListenEventAccess()
        }
    }

    func openSettings() {
        let anchor: String
        switch self {
        case .microphone: anchor = "Privacy_Microphone"
        case .speechRecognition: anchor = "Privacy_SpeechRecognition"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .inputMonitoring: anchor = "Privacy_ListenEvent"
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }

    static var missing: [Permission] { allCases.filter { !$0.isGranted } }
}
