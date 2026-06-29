import SwiftUI

struct PulsingDot: View {
    var size: CGFloat = 10
    @State private var pulse = false
    var body: some View {
        Circle()
            .fill(Color.recordRed)
            .frame(width: size, height: size)
            .opacity(pulse ? 1.0 : 0.4)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}

struct ControlBar: View {
    let isRecording: Bool
    let activeSessionType: SessionType?
    let audioLevel: Float
    let detectedApp: String?
    /// Name of an auto-detected active meeting to offer for the Call Capture filename,
    /// already filtered by dismissal + the global toggle. Nil → no chip.
    let detectedMeetingName: String?
    /// Meeting title applied to the in-flight session (shown in the Stop subtitle).
    let activeMeetingTitle: String?
    let silenceSeconds: Int
    let silenceAutoStopSeconds: Int
    let silencePromptActive: Bool
    let statusMessage: String?
    let errorMessage: String?
    let onStartCallCapture: () -> Void
    let onStartVoiceMemo: () -> Void
    let onStop: () -> Void
    let onKeepRecording: () -> Void
    let onDismissMeeting: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.recordRed)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            }

            if let status = statusMessage, status != "Ready" {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Color.accent1)
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.fg2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }

            if isRecording {
                Button(action: onStop) {
                    HStack(spacing: 10) {
                        PulsingDot(size: 6)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Stop Recording")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color.fg1)
                            Text(activeSessionLabel)
                                .font(.system(size: 10))
                                .foregroundStyle(Color.fg2)
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(Color.accent1.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accent1.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(".", modifiers: .command)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                if silencePromptActive {
                    silenceStopPrompt
                } else if silenceAutoStopSeconds > 0,
                          silenceSeconds >= max(silenceAutoStopSeconds - 30, 1) {
                    Text("Silence — will ask to stop in \(max(silenceAutoStopSeconds - silenceSeconds, 0))s")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 4)
                }
            } else {
                if let meetingName = detectedMeetingName {
                    detectedMeetingChip(meetingName)
                }
                HStack(spacing: 10) {
                    Button(action: onStartCallCapture) {
                        HStack(spacing: 6) {
                            Image(systemName: "phone.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(Color.fg1)
                            Text("Call Capture")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.fg1)
                            Text("⌘R")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.fg3)
                        }
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 8)
                        .background(Color.bg1.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("r", modifiers: .command)

                    Button(action: onStartVoiceMemo) {
                        HStack(spacing: 6) {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(Color.fg1)
                            Text("Voice Memo")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.fg1)
                            Text("⌘⇧R")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.fg3)
                        }
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 8)
                        .background(Color.bg1.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .background(Color.bg1.opacity(0.45))
        .overlay(Divider(), alignment: .top)
    }

    /// Shown when the silence limit elapsed. Recording continues — nothing stops
    /// until the user explicitly picks one of these. `silenceSeconds` keeps
    /// ticking while the prompt is up, so the duration label is live.
    private var silenceStopPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.slash")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("Silent for \(formatSilence(silenceSeconds)) — stop recording?")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                Button(action: onStop) {
                    Text("Stop & Save")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.fg1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.recordRed.opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.recordRed.opacity(0.3)))
                }
                .buttonStyle(.plain)

                Button(action: onKeepRecording) {
                    Text("Keep Recording")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.fg1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.bg1.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.06)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    /// Pre-start chip naming the detected meeting. Tapping ✕ ignores this detection so
    /// Call Capture falls back to the default label (`onDismissMeeting`).
    private func detectedMeetingChip(_ name: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "video.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accent1)
            Text("Meeting: \(name)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.fg1)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Button(action: onDismissMeeting) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.fg3)
            }
            .buttonStyle(.plain)
            .help("Ignore — use the default Call Capture label")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private func formatSilence(_ s: Int) -> String {
        s < 60 ? "\(s)s" : "\(s / 60):\(String(format: "%02d", s % 60))"
    }

    private var activeSessionLabel: String {
        switch activeSessionType {
        case .callCapture:
            if let title = activeMeetingTitle, !title.isEmpty {
                return "Call Capture · \(title)"
            }
            if let app = detectedApp {
                return "Call Capture · \(app)"
            }
            return "Call Capture"
        case .voiceMemo:
            return "Voice Memo"
        case nil:
            return "Recording"
        }
    }
}
