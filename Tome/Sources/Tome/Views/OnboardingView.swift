import AVFoundation
import CoreGraphics
import SwiftUI

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @State private var currentStep = 0

    // Permission state for the final step. Requested HERE, not mid-meeting:
    // the screen-recording grant only takes effect after a relaunch, so a
    // first-ever Call Capture that triggers the prompt has already lost the
    // meeting's "Them" side by the time the user can react.
    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var screenGranted = CGPreflightScreenCaptureAccess()

    private let steps: [(icon: String, title: String, body: String)] = [
        (
            "waveform.circle",
            "Welcome to Tome",
            "A lightweight meeting transcription tool that captures your conversations — all running locally on your Mac. No API keys, no cloud services."
        ),
        (
            "text.quote",
            "Live Transcript",
            "Your conversation is transcribed in real time. \"You\" captures your mic, \"Them\" captures system audio from the other side. The transcript is the primary view — clean and full-window."
        ),
        (
            "lock.shield",
            "Permissions",
            "Tome needs the Microphone for your side of a call and Screen Recording for the other side. Grant both now so your first meeting isn't half-captured."
        ),
    ]

    private var isPermissionsStep: Bool { currentStep == steps.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Icon
            Image(systemName: steps[currentStep].icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.accent1)
                .frame(height: 52)
                .id(currentStep) // force transition on change

            Spacer().frame(height: 20)

            // Title
            Text(steps[currentStep].title)
                .font(.system(size: 16, weight: .semibold))
                .multilineTextAlignment(.center)

            Spacer().frame(height: 10)

            // Body
            Text(steps[currentStep].body)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            if isPermissionsStep {
                Spacer().frame(height: 16)
                permissionRows
            }

            Spacer()

            // Dots
            HStack(spacing: 8) {
                ForEach(0..<steps.count, id: \.self) { i in
                    Circle()
                        .fill(i == currentStep ? Color.accent1 : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.bottom, 20)

            // Buttons
            HStack {
                Button("Skip") {
                    finish()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

                Spacer()

                Button {
                    if currentStep < steps.count - 1 {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            currentStep += 1
                        }
                    } else {
                        finish()
                    }
                } label: {
                    Text(currentStep < steps.count - 1 ? "Next" : "Get Started")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Color.accent1, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bg0)
    }

    // MARK: - Permissions step

    private var permissionRows: some View {
        VStack(spacing: 10) {
            permissionRow(granted: micGranted, label: "Microphone") {
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    Task { @MainActor in micGranted = granted }
                }
            }
            permissionRow(granted: screenGranted, label: "Screen Recording") {
                if !CGPreflightScreenCaptureAccess() {
                    CGRequestScreenCaptureAccess()
                }
                screenGranted = CGPreflightScreenCaptureAccess()
            }
            if !screenGranted {
                Text("macOS applies Screen Recording after Tome is relaunched — grant it here, not mid-meeting.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func permissionRow(granted: Bool, label: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(granted ? Color.accent1 : Color.secondary.opacity(0.5))
            Text(label)
                .font(.system(size: 12, weight: .medium))
            Spacer()
            if !granted {
                Button("Grant") {
                    action()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accent1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.bg1.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func finish() {
        withAnimation(.easeOut(duration: 0.2)) {
            isPresented = false
        }
    }
}
