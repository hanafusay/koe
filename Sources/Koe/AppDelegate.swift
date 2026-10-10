import Cocoa
import Speech

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let directory = SnapshotRenderer.requestedDirectory {
            MainActor.assumeIsolated { SnapshotRenderer.renderAll(to: directory) }
            exit(0)
        }
        if let file = FileTranscriptionProbe.requestedFile {
            Task { @MainActor in
                await FileTranscriptionProbe.run(file: file)
                exit(0)
            }
            return
        }
        Log.d("[AppDelegate] Launch started \(appVersionDescription)")
        checkAllPermissions()
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { KeystrokeTyper.shared.restoreInputSource() }
    }

    private var appVersionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "version=\(version) build=\(build)"
    }

    private func checkAllPermissions() {
        // 1. Accessibility
        let axOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let accessibilityGranted = AXIsProcessTrustedWithOptions(axOptions)
        Log.d("[AppDelegate] Accessibility: \(accessibilityGranted)")
        if !accessibilityGranted {
            DispatchQueue.main.async {
                self.showPermissionAlert(for: .accessibility)
            }
        }

        // 2. Microphone
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        Log.d("[AppDelegate] Microphone: \(micStatus.rawValue)")
        if micStatus != .authorized {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Log.d("[AppDelegate] Microphone granted: \(granted)")
            }
        }

        // 3. Speech Recognition
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        Log.d("[AppDelegate] SpeechRecognition: \(speechStatus.rawValue)")
        if speechStatus != .authorized {
            SFSpeechRecognizer.requestAuthorization { status in
                Log.d("[AppDelegate] SpeechRecognition granted: \(status.rawValue)")
            }
        }
    }

    private func showPermissionAlert(for permission: Permission) {
        let alert = NSAlert()
        alert.messageText = "koe! に権限が必要です"
        alert.informativeText = """
        以下の権限を許可してください：

        ・\(permission.title)（\(permission.purpose)に必要）

        「\(permission.title)を開く」を押して、koe! を追加・許可してください。
        許可後、アプリを再起動してください。
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "\(permission.title)を開く")
        alert.addButton(withTitle: "後で")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            permission.openSettings()
        }
    }
}
