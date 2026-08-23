import SwiftUI

/// Presented when a meeting is longer than Apple's on-device model can read in
/// one pass.
///
/// The alternative was to summarise anyway and say nothing. That produces a
/// worse write-up for a reason invisible to the person reading it — the model
/// read the meeting in eleven pieces and stitched the notes together, losing
/// material at every seam. Naming the constraint costs one decision, once.
struct SummaryChoiceCard: View {
    let choice: SummaryService.PendingChoice

    @ObservedObject private var summaries = SummaryService.shared
    @ObservedObject private var localModel = LocalLanguageModel.shared
    @ObservedObject private var ui = UIState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.split.3x1")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text("This meeting is longer than the built-in model can read at once")
                        .font(Theme.medium(13))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(choice.words.formatted()) words. Apple's on-device model holds about 2,000 at a time, so it would read this in \(choice.pieces) pieces and stitch the notes together — which loses detail at every join.")
                        .font(Theme.body(11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            Divider().overlay(Theme.borderSoft)

            option(
                symbol: "internaldrive",
                tint: Theme.live,
                title: "Use \(LocalLanguageModel.displayName) — stays on this Mac",
                detail: "Reads the whole meeting in one pass. Downloads about \(LocalLanguageModel.downloadSize) once, then works offline forever, like the rest of the app. Nothing is ever sent anywhere."
            ) {
                if localModel.isReady || !localModel.isDownloading {
                    Button("Download and Summarise") { summaries.acceptLocalModel() }
                        .buttonStyle(PrimaryButtonStyle())
                }
            }

            if localModel.isDownloading {
                downloadProgress
            }

            option(
                symbol: "arrow.up.forward.app",
                tint: Theme.textSecondary,
                title: "Send it to ChatGPT or Claude",
                detail: "Copies the meeting and a prompt, then opens the site so you can paste it. These leave your Mac — that is the trade for not downloading anything. Roughly \(SummaryHandoff.approximateTokens(choice.transcript).formatted()) tokens."
            ) {
                HStack(spacing: 6) {
                    ForEach(SummaryHandoff.Provider.allCases) { provider in
                        Button(provider.displayName) {
                            SummaryHandoff.send(choice.transcript, to: provider)
                            summaries.cancelChoice()
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }
            }

            option(
                symbol: "checkmark.circle",
                tint: Theme.textTertiary,
                title: "Carry on with the built-in model",
                detail: "You still get a summary. It will be less complete than one written from the whole meeting at once."
            ) {
                HStack(spacing: 6) {
                    Button("Summarise Anyway") { summaries.continueWithApple(remember: false) }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("Always") { summaries.continueWithApple(remember: true) }
                        .buttonStyle(GhostButtonStyle())
                        .help("Stop offering this and always use the built-in model.")
                }
            }

            HStack {
                Spacer()
                Button("Not Now") { summaries.cancelChoice() }
                    .buttonStyle(GhostButtonStyle())
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Theme.radiusCard).fill(Theme.raised))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusCard)
                .strokeBorder(Theme.warning.opacity(0.28), lineWidth: 1)
        )
        .transition(.opacity.combined(with: .offset(y: -8)))
        .animation(Theme.spring, value: localModel.state)
    }

    private var downloadProgress: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localModel.statusText)
                .font(Theme.body(11.5))
                .foregroundStyle(Theme.textSecondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hover)
                    Capsule().fill(Theme.live)
                        .frame(width: max(3, geo.size.width * (localModel.state.fraction ?? 0)))
                }
            }
            .frame(height: 4)
            .animation(Theme.quick, value: localModel.state.fraction)
            Text("Downloads once. After this it runs offline and never asks again.")
                .font(Theme.body(10.5))
                .foregroundStyle(Theme.textTertiary.opacity(0.8))
        }
        .padding(.leading, 26)
    }

    @ViewBuilder
    private func option<Actions: View>(
        symbol: String,
        tint: Color,
        title: String,
        detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(Theme.medium(12.5))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(Theme.body(11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                actions()
            }
            Spacer(minLength: 0)
        }
    }
}
