import AppKit
import SwiftUI
import CoreAudio
import Sparkle

/// Settings tabs, addressable so other parts of the app can open Settings on a
/// specific one — the mixer lean-in prompt routes straight to Audio.
enum SettingsTab: Hashable {
    case general, audio, transcription, output, api
}

struct SettingsView: View {
    @Bindable var settings: AppSettings
    var updater: SPUUpdater
    let services: AppServices

    var body: some View {
        TabView(selection: Bindable(services).settingsTab) {
            GeneralTab(settings: settings, updater: updater)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            AudioTab(settings: settings)
                .tabItem { Label("Audio", systemImage: "mic.fill") }
                .tag(SettingsTab.audio)
            TranscriptionTab(settings: settings, services: services)
                .tabItem { Label("Transcription", systemImage: "waveform") }
                .tag(SettingsTab.transcription)
            OutputTab(settings: settings)
                .tabItem { Label("Output", systemImage: "folder.fill") }
                .tag(SettingsTab.output)
            APITab()
                .tabItem { Label("API", systemImage: "network") }
                .tag(SettingsTab.api)
        }
        .frame(width: 520, height: 480)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Bindable var settings: AppSettings
    var updater: SPUUpdater

    var body: some View {
        Form {
            Section("Updates") {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }
                ))
                .font(.system(size: 12))
            }

            Section("Privacy") {
                Toggle("Hide from screen sharing", isOn: $settings.hideFromScreenShare)
                    .font(.system(size: 12))
                Text("When enabled, the app is invisible during screen sharing and recording.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Audio

/// Live input-device list: enumerates on start and re-enumerates whenever
/// CoreAudio's device set changes (AirPods connecting, USB mic plugged in)
/// or the HAL wedge latch clears (an enumeration attempted during a wedge is
/// refused and must be retried once the driver recovers — the clear is not a
/// device-set change, so the CoreAudio listener alone would leave the pickers
/// stuck on "(unavailable)" forever; 2026-07-26 incident).
/// The previous enumerate-once-in-onAppear left newly attached devices
/// invisible until the user bounced between Settings tabs.
@Observable
@MainActor
private final class InputDeviceList {
    private(set) var devices: [(id: AudioDeviceID, uid: String, name: String)] = []
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var wedgeObserver: (any NSObjectProtocol)?

    private var devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    /// In-flight (possibly debounced) enumeration. One at a time — a newer
    /// trigger supersedes an older pending one.
    private var refreshTask: Task<Void, Never>?

    func start() {
        refresh(debounced: false)
        if wedgeObserver == nil {
            wedgeObserver = NotificationCenter.default.addObserver(
                forName: HALQueue.wedgeClearedNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh(debounced: false) }
            }
        }
        guard listenerBlock == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh(debounced: true) }
        }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &devicesAddress, DispatchQueue.main, block
        )
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        if let wedgeObserver { NotificationCenter.default.removeObserver(wedgeObserver) }
        wedgeObserver = nil
        guard let block = listenerBlock else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &devicesAddress, DispatchQueue.main, block
        )
        listenerBlock = nil
    }

    /// Enumerate off the main actor (the async overload hops to the HAL queue
    /// with a deadline — a wedged driver must not freeze the Settings window),
    /// debounced when triggered by a device-set change notification: a driver
    /// initializing emits a storm of those, and enumerating on each one both
    /// hammers the HAL and churns the picker (2026-07-25 hang spec, Part D).
    private func refresh(debounced: Bool) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            if debounced {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
            }
            let enumerated = await MicCapture.availableInputDevicesResult()
            guard !Task.isCancelled else { return }
            // An unanswered enumeration is not an empty machine. Keep the
            // current list instead of rendering every selection "(unavailable)"
            // — the wedge-cleared notification re-runs this refresh once the
            // driver recovers. (Enumeration runs on the query lane, so a wedged
            // capture bind no longer stalls it at all; this guard now only
            // covers a query lane that is itself stuck.)
            guard case .answered(let devices) = enumerated else { return }
            self?.devices = devices
        }
    }
}

private struct AudioTab: View {
    @Bindable var settings: AppSettings
    @State private var deviceList = InputDeviceList()

    /// True when the persisted selection points at a device that isn't present
    /// right now (unplugged USB mic, an audio router's virtual device while the
    /// router app is closed). The selection is kept — shown as "(unavailable)" —
    /// instead of being reset, so it survives reboots and router restarts.
    private var selectionUnavailable: Bool {
        !settings.inputDeviceUID.isEmpty
            && !deviceList.devices.contains(where: { $0.uid == settings.inputDeviceUID })
    }

    /// Same "(unavailable)" treatment for the call-audio source. A mixer's
    /// virtual device is absent whenever its driver is unloaded, and the
    /// selection must survive that rather than silently resetting to automatic.
    private var callAudioSourceUnavailable: Bool {
        !settings.systemAudioSourceUID.isEmpty
            && !deviceList.devices.contains(where: { $0.uid == settings.systemAudioSourceUID })
    }

    /// Selection-time warning for the one configuration that cannot work: the
    /// same device on both legs. The engine refuses it outright at bind time
    /// (`resolveSystemSource`) — this is the earlier, friendlier signal.
    private var callAudioSourceIsMic: Bool {
        !settings.systemAudioSourceUID.isEmpty
            && settings.systemAudioSourceUID == settings.inputDeviceUID
    }

    var body: some View {
        Form {
            Section("Input") {
                Picker("Microphone", selection: $settings.inputDeviceUID) {
                    Text("System Default (recommended)").tag("")
                    // Devices with no readable UID can't round-trip through a
                    // UID-keyed selection (and would collide on the "" tag).
                    ForEach(deviceList.devices.filter { !$0.uid.isEmpty }, id: \.uid) { device in
                        Text(device.name).tag(device.uid)
                    }
                    if selectionUnavailable {
                        Text("\(settings.inputDeviceName.isEmpty ? "Selected microphone" : settings.inputDeviceName) (unavailable)")
                            .tag(settings.inputDeviceUID)
                    }
                }
                .font(.system(size: 12))
                .onChange(of: settings.inputDeviceUID) { _, newUID in
                    // Keep the display name in sync for the "(unavailable)" row.
                    if let device = deviceList.devices.first(where: { $0.uid == newUID }) {
                        settings.inputDeviceName = device.name
                    } else if newUID.isEmpty {
                        settings.inputDeviceName = ""
                    }
                }
                Text("System Default follows macOS — when AirPods connect, recording moves with them. Pinning a specific mic keeps recording on that device across docking: while it's unplugged Tome records from System Default and says so, then moves back to your pick the moment it reappears, even mid-recording. Pinning does fight macOS's automatic switching and can drop out during Bluetooth transitions; if a pinned mic keeps failing mid-session, Tome falls back to System Default for that session.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // The whole surface of this section is the source picker. The
            // audio-router exclusion list still ships (it is what makes
            // automatic mode safe on a machine where a router is running) but
            // it needs no per-user decisions now that mixer owners can just
            // subscribe to a mix — see AppSettings.excludedAudioAppIDs.
            Section("System Audio") {
                Picker("Call audio source", selection: $settings.systemAudioSourceUID) {
                    Text("System audio (automatic)").tag("")
                    ForEach(deviceList.devices.filter { !$0.uid.isEmpty }, id: \.uid) { device in
                        Text(device.name).tag(device.uid)
                    }
                    if callAudioSourceUnavailable {
                        Text("\(settings.systemAudioSourceName.isEmpty ? "Selected device" : settings.systemAudioSourceName) (unavailable)")
                            .tag(settings.systemAudioSourceUID)
                    }
                }
                .font(.system(size: 12))
                .onChange(of: settings.systemAudioSourceUID) { _, newUID in
                    if let device = deviceList.devices.first(where: { $0.uid == newUID }) {
                        settings.systemAudioSourceName = device.name
                    } else if newUID.isEmpty {
                        settings.systemAudioSourceName = ""
                    }
                }

                if callAudioSourceIsMic {
                    Label(
                        "This is your microphone device — Tome would hear you twice. Pick a mix that excludes your mic.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                }

                Text("Automatic captures every app's audio and filters out known audio routers and media players. If you run a mixer (Elgato Wave Link, Loopback, RØDE UNIFY), you can do better: build a mix containing the call/app audio with your own mic channel muted, then select that mix's device here. Verify it in QuickTime — record from the device and your voice must be absent.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Switch back to \u{201C}System audio (automatic)\u{201D} when the mixer app isn't running: its virtual devices stay listed while it's closed and deliver pure silence, so Tome can't tell from the device list alone. If you forget, Tome warns a few seconds into the recording. Changes apply at the next recording.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Silence") {
                HStack {
                    Text("Silence Timeout")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(settings.silenceAutoStopSeconds == 0 ? "Off" : "\(settings.silenceAutoStopSeconds)s")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
                Slider(value: Binding(
                    get: { Double(settings.silenceAutoStopSeconds) },
                    set: { settings.silenceAutoStopSeconds = Int($0) }
                ), in: 0...600, step: 30)
                Text("Ask to stop recording after this many seconds of silence (mic + system audio). Recording never stops without your confirmation. 0 disables the prompt. Default: 120s")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { deviceList.start() }
        .onDisappear { deviceList.stop() }
    }
}

// MARK: - Transcription

private struct TranscriptionTab: View {
    @Bindable var settings: AppSettings
    let services: AppServices

    var body: some View {
        Form {
            Section("Model") {
                Picker(selection: $settings.transcriberModel) {
                    ForEach(TranscriberModel.allCases, id: \.self) { model in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName)
                                .font(.system(size: 12, weight: .medium))
                            Text(rowSubtitle(for: model))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .tag(model)
                    }
                } label: {
                    Text("Model").font(.system(size: 12, weight: .medium))
                }
                .pickerStyle(.radioGroup)
                .disabled(modelChangeLocked)

                if modelChangeLocked {
                    Text("Model changes are disabled while recording or processing.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                modelStatusLine
            }

            Section("Language") {
                // Read-only for now — locale switching isn't wired up yet, so show
                // the active value rather than letting it be edited into a no-op.
                HStack {
                    Text("Locale")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(settings.transcriptionLocale)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
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

                HStack {
                    Text("Same-Speaker Merge Gap")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(String(format: "%.2fs", settings.diarizationMergeGapSeconds))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
                Slider(value: $settings.diarizationMergeGapSeconds, in: 0.0...3.0, step: 0.25)
                Text("Merges a speaker's consecutive segments up to this pause into one block — higher combines sentence fragments into paragraphs. Never merges different speakers. Default: 1.50s")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Provision from Settings too, so a model change still takes effect when
        // the main window is closed (app alive via MenuBarExtra) and ContentView's
        // onChange isn't live (audit F-4). ContentView.onChange(of:
        // settings.transcriberModel) mirrors this; provision() is idempotent
        // (in-flight/serving guards) so a duplicate call from the live window is a
        // no-op.
        .onChange(of: settings.transcriberModel) { _, model in
            services.modelProvisioner.provision(model)
        }
    }

    /// Spec §4a: no swap may land mid-recording, mid-post-processing, or
    /// mid-recovery — a job re-transcribed by two models is a quality bug.
    /// `isSessionPending` closes the start/stop transition windows that
    /// `isRecording` misses (audit F-2).
    private var modelChangeLocked: Bool {
        services.isRecording
            || services.postProcessingQueue.isAnyJobRunning
            || services.isRecovering
            || services.isSessionPending
    }

    /// Per-row install state (spec §6): each row describes ITSELF; the
    /// status line below describes the selected model's provisioning.
    private func rowSubtitle(for model: TranscriberModel) -> String {
        let installState = model.isInstalled
            ? "Downloaded ✓"
            : "Not downloaded (\(model.approxDownloadSize))"
        return "\(model.pickerSubtitle) · \(installState)"
    }

    @ViewBuilder private var modelStatusLine: some View {
        let provisioner = services.modelProvisioner
        switch provisioner.activity {
        case .downloading(_, let progress):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(progress.map { "Downloading… \(Int($0 * 100))%" } ?? "Downloading…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Loading model…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .none:
            if let failure = provisioner.lastFailure {
                HStack(spacing: 8) {
                    Text("\(failure.model.displayName): \(failure.message)")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.recordRed)
                    Button("Retry") { provisioner.retry() }
                        .font(.system(size: 11))
                        .disabled(modelChangeLocked)
                }
            } else if provisioner.servingModel == settings.transcriberModel {
                Text("Active ✓")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text("Loading model…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Output

private struct OutputTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Vault Folders") {
                folderRow(
                    title: "Meetings",
                    path: settings.vaultMeetingsPath,
                    chooseMessage: "Choose the folder for meeting transcripts"
                ) { settings.vaultMeetingsPath = $0 }

                folderRow(
                    title: "Voice Memos",
                    path: settings.vaultVoicePath,
                    chooseMessage: "Choose the folder for voice memo transcripts"
                ) { settings.vaultVoicePath = $0 }
            }

            Section("Discard Short Meetings") {
                Toggle("Discard canceled or mis-started meetings", isOn: $settings.discardShortMeetings)
                    .font(.system(size: 12))
                if settings.discardShortMeetings {
                    HStack {
                        Text("Threshold")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("\(settings.discardShortMeetingSeconds)s")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                    Slider(value: Binding(
                        get: { Double(settings.discardShortMeetingSeconds) },
                        set: { settings.discardShortMeetingSeconds = Int($0) }
                    ), in: 5...300, step: 5)
                }
                Text("Call captures that stop at or under this length are treated as canceled meetings: the transcript and any recording are deleted instead of saved. Voice memos are never discarded. Off by default.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Recordings") {
                Toggle("Retain recordings", isOn: $settings.retainRecordings)
                    .font(.system(size: 12))
                if settings.retainRecordings {
                    folderRow(
                        title: "Recordings Folder",
                        path: settings.recordingsFolderPath,
                        chooseMessage: "Choose the folder for retained recordings"
                    ) { settings.recordingsFolderPath = $0 }
                }
                Text(".m4a, ~25 MB/hour. Combines your mic and the other side into one file.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Speaker Voiceprints") {
                Toggle("Export speaker voiceprints", isOn: $settings.exportVoiceprints)
                    .font(.system(size: 12))
                Text("Writes a per-speaker voice embedding (.voiceprints.json) next to each call transcript so other tools can recognize returning speakers. Biometric data; stays on your machine. Off by default.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Filename Template") {
                filenameRow(label: "Date Format", binding: $settings.filenameDateFormat, monospaced: true)
                filenameRow(label: "Call Capture Label", binding: $settings.filenameCallLabel)
                filenameRow(label: "Voice Memo Label", binding: $settings.filenameVoiceLabel)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Preview")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(filenamePreview(label: settings.filenameCallLabel.isEmpty ? "Call Recording" : settings.filenameCallLabel))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(filenamePreview(label: settings.filenameVoiceLabel.isEmpty ? "Voice Memo" : settings.filenameVoiceLabel))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("Forbidden filesystem characters (/ : \\ ? * < > | \") are converted to dashes. Leave a label blank for date-only filenames.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Toggle("Auto-name from detected meetings", isOn: $settings.useDetectedMeetingNames)
                    .font(.system(size: 12))
                Text("When you're in a Teams or Google Meet call, use the meeting's name for the Call Capture filename instead of the label above. The detected name appears as a dismissible chip, so you can ignore a false match. Names supplied over the API always take priority.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func folderRow(title: String, path: String, chooseMessage: String, onSelect: @escaping (String) -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(path.isEmpty ? "No folder selected" : path)
                    .font(.system(size: 11))
                    .foregroundStyle(path.isEmpty ? .tertiary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Choose...") {
                chooseFolder(message: chooseMessage, onSelect: onSelect)
            }
        }
    }

    @ViewBuilder
    private func filenameRow(label: String, binding: Binding<String>, monospaced: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 160, alignment: .leading)
            TextField("", text: binding)
                .font(.system(size: 12, design: monospaced ? .monospaced : .default))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
        }
    }

    private func filenamePreview(label: String) -> String {
        let datePrefix = FilenameSanitizer.formattedDate(Date(), format: settings.filenameDateFormat)
        let sanitizedLabel = FilenameSanitizer.sanitize(label) ?? ""
        let stem = sanitizedLabel.isEmpty ? datePrefix : "\(datePrefix) \(sanitizedLabel)"
        return "\(stem).md"
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

// MARK: - API

private struct APITab: View {
    @State private var apiPort: String?
    @State private var copiedURL = false

    var body: some View {
        Form {
            Section("Base URL") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(apiBaseURL)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                        Text("Localhost-only REST API for external integrations.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(apiBaseURL, forType: .string)
                        copiedURL = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedURL = false }
                    } label: {
                        Image(systemName: copiedURL ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 12))
                            .foregroundStyle(copiedURL ? .green : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy base URL")
                }
            }

            Section("Endpoints") {
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
        }
        .formStyle(.grouped)
        .onAppear {
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
}
