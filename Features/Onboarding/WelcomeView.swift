import SwiftUI

struct WelcomeView: View {
    @Binding var hasCompletedOnboarding: Bool
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled = false
    @ObservedObject private var syncManager = SyncManager.shared

    /// Discord (Glitzbr): he turned iCloud sync on during setup and a
    /// customised remote map from a different-generation Apple TV landed on
    /// this one. By the time he found the Sync Categories screen the data had
    /// already arrived, so the choice has to be offered BEFORE the first pull
    /// - which is what this sheet does. Logan 2026-08-10.
    @State private var showCategoryChooser = false

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            // Background gradient orbs
            GeometryReader { geo in
                Circle()
                    .fill(Color.accentPrimary.opacity(0.12))
                    .frame(width: 400, height: 400)
                    .blur(radius: 80)
                    .offset(x: -100, y: -80)

                Circle()
                    .fill(Color.accentSecondary.opacity(0.10))
                    .frame(width: 300, height: 300)
                    .blur(radius: 60)
                    .offset(x: geo.size.width - 150, y: geo.size.height - 200)
            }
            .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    // Logo / Icon
                    Image("AstralLogo")
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: Color(hex: "1AC4D8").opacity(0.45), radius: 20, y: 8)
                        .padding(.top, 16)
                        .padding(.bottom, 20)

                    // Title
                    VStack(spacing: 4) {
                        Text("AstralTV")
                            .scaledFont(.displayLarge)
                            .foregroundColor(.textPrimary)
                        Text("Your IPTV & Media Hub")
                            .scaledFont(.bodyLarge.subtext())
                            .foregroundColor(Color.contrastText(.textSecondary))
                        Text("iPhone, iPad, Apple TV, & Mac")
                            .scaledFont(.bodySmall.subtext())
                            .foregroundColor(Color.contrastText(.textTertiary))
                    }
                    .padding(.bottom, 24)

                    // Supported source types
                    VStack(spacing: 8) {
                        FeaturePill(icon: "key.fill", title: "Dispatcharr Direct Connect")
                        FeaturePill(icon: "tv.and.hifispeaker.fill", title: "Xtream Codes")
                        FeaturePill(icon: "doc.text.fill", title: "M3U + EPG")
                    }
                    .padding(.bottom, 20)

                    // iCloud Sync opt-in
                    iCloudSyncToggle
                        .padding(.horizontal, 32)
                        .padding(.bottom, 12)

                    // Keep the vertical rhythm between the iCloud row
                    // and the CTA below.
                    Spacer().frame(height: 8)

                    // CTA
                    VStack(spacing: 10) {
                        NavigationLink(destination: AddServerView()) {
                            HStack(spacing: 8) {
                                Image(systemName: "server.rack")
                                    .scaledFont(.system(size: 15, weight: .semibold))
                                Text("Connect a Server")
                                    .scaledFont(.headlineMedium)
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 48)
                            .background(LinearGradient.accentGradient)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button("Skip for now") {
                            hasCompletedOnboarding = true
                        }
                        .scaledFont(.bodyMedium)
                        .foregroundColor(Color.contrastText(.textTertiary))
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showCategoryChooser) {
            OnboardingSyncCategoryChooser(
                onContinue: {
                    showCategoryChooser = false
                    // Only NOW does anything come down: the categories the
                    // user just chose are already written, and
                    // syncSettingChanged is what kicks off the first pull.
                    iCloudSyncEnabled = true
                    SyncManager.shared.syncSettingChanged(enabled: true)
                },
                onCancel: {
                    showCategoryChooser = false
                    // Backing out leaves sync off entirely - nothing was
                    // pulled, so there is nothing to undo.
                }
            )
        }
    }

    /// Turning sync ON opens the chooser first and defers the pull until the
    /// user confirms; turning it OFF is immediate.
    private func toggleICloudSync() {
        if iCloudSyncEnabled {
            iCloudSyncEnabled = false
            SyncManager.shared.syncSettingChanged(enabled: false)
        } else {
            showCategoryChooser = true
        }
    }

    // MARK: - Default Live TV View Picker

    // MARK: - iCloud Import Button

    private var iCloudSyncToggle: some View {
        Button {
            guard !syncManager.isImporting else { return }
            toggleICloudSync()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentPrimary.opacity(0.15))
                        .frame(width: 36, height: 36)
                    if syncManager.isImporting {
                        ProgressView()
                            .tint(.accentPrimary)
                    } else {
                        Image(systemName: iCloudSyncEnabled ? "checkmark.icloud.fill" : "icloud.fill")
                            .scaledFont(.system(size: 15, weight: .medium))
                            .foregroundColor(.accentPrimary)
                    }
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(syncManager.isImporting ? "Importing from iCloud…"
                         : iCloudSyncEnabled ? "iCloud Sync Enabled"
                         : "Sync via iCloud")
                        .scaledFont(.headlineSmall)
                        .foregroundColor(.textPrimary)
                    Text(syncManager.isImporting ? "Looking for an existing configuration…"
                         : iCloudSyncEnabled
                         ? "Settings synced across all your devices"
                         : "Use if you've enabled Astral iCloud sync on another device")
                        .scaledFont(.bodySmall.subtext())
                        .foregroundColor(Color.contrastText(.textSecondary))
                        .lineLimit(2)
                }

                Spacer()

                if syncManager.isImporting {
                    ProgressView()
                        .tint(.accentPrimary)
                } else {
                    Image(systemName: iCloudSyncEnabled ? "checkmark.circle.fill" : "circle")
                        .scaledFont(.system(size: 20))
                        .foregroundColor(iCloudSyncEnabled ? .accentPrimary : Color.contrastText(.textTertiary))
                }
            }
            .padding(12)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(iCloudSyncEnabled ? Color.accentPrimary.opacity(0.4) : Color.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(syncManager.isImporting)
    }
}

// MARK: - tvOS Onboarding Components

// MARK: - Feature Bullet
/// Non-interactive feature row, intentionally styled without card backgrounds,
/// borders, or trailing chevrons/checkmarks so it reads as informational text,
/// not a tappable button.
private struct FeaturePill: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .scaledFont(.system(size: 15, weight: .semibold))
                .foregroundStyle(LinearGradient.accentGradient)
                .frame(width: 24)

            Text(title)
                .scaledFont(.headlineSmall)
                .foregroundColor(.textPrimary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Onboarding Sync Category Chooser

/// Shown the moment the user opts into iCloud sync during setup, BEFORE the
/// first pull runs.
///
/// Discord (Glitzbr, 2026-08-10): he enabled sync on a second Apple TV and a
/// remote button map customised for a different-generation remote came down
/// with everything else. The per-category controls already existed, but they
/// live in Settings, and by the time you go looking for them the data has
/// already landed. Logan's call: ask during onboarding, when the answer still
/// changes the outcome.
///
/// Everything defaults ON, so the common case is one press. The toggles write
/// the same `syncEnabled.<rawValue>` defaults keys the Settings screen binds
/// to - one source of truth, and a choice made here shows up there.
struct OnboardingSyncCategoryChooser: View {
    let onContinue: () -> Void
    let onCancel: () -> Void

    /// Local until Continue, so backing out cannot leave a half-applied set.
    @State private var selection: [SyncCategory: Bool] = Dictionary(
        uniqueKeysWithValues: SyncCategory.allCases.map { ($0, $0.defaultEnabled) }
    )

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("What should come in from iCloud?")
                            .scaledFont(.headlineLarge)
                            .foregroundColor(.textPrimary)
                        Text("You can change any of this later in Settings, and each device chooses for itself.")
                            .scaledFont(.bodySmall.subtext())
                            .foregroundColor(Color.contrastText(.textSecondary))
                    }

                    // Rows sit directly on the sheet, each carrying its own
                    // card. They used to be dividers inside ANOTHER rounded
                    // card, which read as pills nested in a pill.
                    VStack(spacing: 8) {
                        ForEach(SyncCategory.allCases) { category in
                            let binding = Binding(
                                get: { selection[category] ?? category.defaultEnabled },
                                set: { selection[category] = $0 }
                            )
                            Toggle(isOn: binding) {
                                SettingsRow(icon: category.icon,
                                            iconColor: .accentPrimary,
                                            title: category.displayName,
                                            subtitle: category.briefSubtitle)
                            }
                            .tint(.accentPrimary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.elevatedBackground)
                            )
                        }
                    }

                    VStack(spacing: 10) {
                        let commit = {
                            // Commit BEFORE the caller starts the pull.
                            for (category, isOn) in selection {
                                UserDefaults.standard.set(isOn, forKey: category.defaultsKey)
                            }
                            onContinue()
                        }
                        Button(action: commit) {
                            Text("Turn On iCloud Sync")
                                .scaledFont(.headlineMedium)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 48)
                                .background(LinearGradient.accentGradient)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button("Not now", action: onCancel)
                            .scaledFont(.bodyMedium)
                            .foregroundColor(.textTertiary)
                    }
                }
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
                .padding(24)
            }
        }
    }
}
