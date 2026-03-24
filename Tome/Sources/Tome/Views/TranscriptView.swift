import SwiftUI

struct TranscriptView: View {
    let utterances: [Utterance]
    let volatileYouText: String
    let volatileThemText: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(utterances) { utterance in
                        UtteranceBubble(utterance: utterance)
                            .id(utterance.id)
                    }

                    if !volatileYouText.isEmpty {
                        VolatileIndicator(text: volatileYouText, speaker: .you)
                            .id("volatile-you")
                    }

                    if !volatileThemText.isEmpty {
                        VolatileIndicator(text: volatileThemText, speaker: .them)
                            .id("volatile-them")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: utterances.count) {
                withAnimation(.easeOut(duration: 0.2)) {
                    if let last = utterances.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: volatileYouText) {
                proxy.scrollTo("volatile-you", anchor: .bottom)
            }
            .onChange(of: volatileThemText) {
                proxy.scrollTo("volatile-them", anchor: .bottom)
            }
        }
    }
}

private struct UtteranceBubble: View {
    let utterance: Utterance

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(utterance.speaker == .you ? "You" : "Them")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(utterance.speaker == .you ? Color.accent1 : Color.fg2)
                .frame(width: 36, alignment: .trailing)

            Text(utterance.text)
                .font(.system(size: 13))
                .foregroundStyle(Color.fg1)
                .textSelection(.enabled)
        }
    }
}

private struct VolatileIndicator: View {
    let text: String
    let speaker: Speaker

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(speaker == .you ? "You" : "Them")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(speaker == .you ? Color.accent1 : Color.fg2)
                .frame(width: 36, alignment: .trailing)

            HStack(spacing: 4) {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.fg3)
                Circle()
                    .fill(Color.accent1)
                    .frame(width: 4, height: 4)
            }
        }
        .opacity(0.5)
    }
}

// MARK: - Design Tokens

extension Color {
    // Backgrounds
    static let bg0 = Color(red: 0.05, green: 0.05, blue: 0.06)   // near black
    static let bg1 = Color(red: 0.09, green: 0.09, blue: 0.10)   // card/surface
    static let bg2 = Color(red: 0.13, green: 0.13, blue: 0.14)   // elevated

    // Foregrounds
    static let fg1 = Color(red: 0.92, green: 0.92, blue: 0.93)   // primary text
    static let fg2 = Color(red: 0.55, green: 0.55, blue: 0.58)   // secondary text
    static let fg3 = Color(red: 0.35, green: 0.35, blue: 0.38)   // tertiary/muted

    // Accent — Obsidian-inspired purple
    static let accent1 = Color(red: 0.66, green: 0.55, blue: 0.98)  // #A88BFA
    static let accent2 = Color(red: 0.50, green: 0.40, blue: 0.75)  // dimmer variant
}
