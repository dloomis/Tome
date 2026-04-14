import SwiftUI
import CoreAudio
import Sparkle

struct SettingsView: View {
    @Bindable var settings: AppSettings
    var updater: SPUUpdater
    @State private var inputDevices: [(id: AudioDeviceID, name: String)] = []
    @State private var apiPort: String?
    @State private var copiedURL = false

    var body: some View {
        Form {
            Section("Output Folders") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Meetings")
                            .font(.system(size: 12, weight: .medium))
                        Text(settings.vaultMeetingsPath.isEmpty ? "No folder selected" : settings.vaultMeetingsPath)
                            .font(.system(size: 11))
                            .foregroundStyle(settings.vaultMeetingsPath.isEmpty ? .tertiary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    Button("Choose...") {
                        chooseFolder(message: "Choose the folder for meeting transcripts") { path in
                            settings.vaultMeetingsPath = path
                        }
                    }
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Voice Memos")
                            .font(.system(size: 12, weight: .medium))
                        Text(settings.vaultVoicePath.isEmpty ? "No folder selected" : settings.vaultVoicePath)
                            .font(.system(size: 11))
                            .foregroundStyle(settings.vaultVoicePath.isEmpty ? .tertiary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    Button("Choose...") {
                        chooseFolder(message: "Choose the folder for voice memo transcripts") { path in
                            settings.vaultVoicePath = path
                        }
                    }
                }
            }

            Section("Audio Input") {
                Picker("Microphone", selection: $settings.inputDeviceID) {
                    Text("System Default").tag(AudioDeviceID(0))
                    ForEach(inputDevices, id: \.id) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .font(.system(size: 12))
            }

            Section("Transcription") {
                TextField("Locale (e.g. en-US)", text: $settings.transcriptionLocale)
                    .font(.system(size: 12, design: .monospaced))
            }

            Section("Speaker Diarization") {
                HStack {
                    Text("Cluster Distance Threshold")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(String(format: "%.2f", settings.diarizationClusterThreshold))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
                Slider(value: $settings.diarizationClusterThreshold, in: 0.3...1.0, step: 0.05)
                Text("Lower = more speakers detected. Default: 0.70")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Stepper("Number of Speakers: \(settings.diarizationNumberOfSpeakers)", value: $settings.diarizationNumberOfSpeakers, in: 0...10)
                    .font(.system(size: 12))
                Text("Expected speaker count. 0 = automatic. Default: 0")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Toggle("Hide from screen sharing", isOn: $settings.hideFromScreenShare)
                    .font(.system(size: 12))
                Text("When enabled, the app is invisible during screen sharing and recording.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Local API") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Base URL")
                            .font(.system(size: 12, weight: .medium))
                        Text("Localhost-only REST API for external integrations.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        Text(apiBaseURL)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(apiBaseURL, forType: .string)
                            copiedURL = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                copiedURL = false
                            }
                        } label: {
                            Image(systemName: copiedURL ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11))
                                .foregroundStyle(copiedURL ? .green : .secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Copy base URL")
                    }
                }

                DisclosureGroup("Endpoints") {
                    ForEach(apiEndpoints, id: \.path) { endpoint in
                        HStack(alignment: .top, spacing: 6) {
                            Text(endpoint.method)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(endpoint.method == "GET" ? .green : .orange)
                                .frame(width: 34, alignment: .leading)
                            Text(endpoint.path)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            Text(endpoint.description)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .font(.system(size: 12))
            }

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }
                ))
                .font(.system(size: 12))
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 620)
        .onAppear {
            inputDevices = MicCapture.availableInputDevices()
            if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                let portFile = appSupport.appendingPathComponent("Tome/api-port")
                apiPort = try? String(contentsOf: portFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private var apiBaseURL: String {
        "http://127.0.0.1:\(apiPort ?? "…")/api/v1"
    }

    private var apiEndpoints: [(method: String, path: String, description: String)] {
        [
            ("GET",  "/",                             "OpenAPI spec"),
            ("GET",  "/health",                       "Status & model readiness"),
            ("GET",  "/status",                       "Session lifecycle state"),
            ("POST", "/start",                        "Start call capture"),
            ("POST", "/stop",                         "Stop recording"),
            ("GET",  "/sessions",                     "List sessions"),
            ("POST", "/sessions/start",               "Start session (generic)"),
            ("POST", "/sessions/stop",                "Stop active session"),
            ("GET",  "/sessions/{id}/status",         "Session status"),
            ("GET",  "/sessions/{id}/transcript",     "Session transcript"),
        ]
    }

    private func chooseFolder(message: String, onSelect: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message

        if panel.runModal() == .OK, let url = panel.url {
            onSelect(url.path)
        }
    }
}
