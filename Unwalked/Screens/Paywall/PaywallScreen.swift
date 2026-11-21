import MapKit
import SwiftUI

struct PaywallScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var plan: Purchases.Plan = .yearly
    @State private var position: MapCameraPosition = .automatic

    private var purchases: Purchases { model.purchases }

    var body: some View {
        ZStack(alignment: .bottom) {
            UnwalkedMap(layers: MapLayers(walked: model.library.walkedPaths, home: model.home),
                        position: $position, interactive: false)

            VStack {
                HStack {
                    Spacer()
                    GlassIconButton(systemName: "xmark", label: "Close") { dismiss() }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                Spacer()
            }

            BottomSheet(bottomPadding: 22) {
                SheetTitle(text: "You have walked both free loops this week").padding(.top, 16)
                BodyText(text: "Unwalked Plus gives you a fresh loop whenever you want one. Recording and your map stay free, and your next free loop arrives on Monday.")
                    .padding(.top, 8)

                VStack(spacing: 8) {
                    ForEach(Purchases.Plan.allCases) { p in
                        ChoiceRow(isSelected: plan == p, height: 68, action: { plan = p }) {
                            TitleSubtitle(title: p.label, subtitle: purchases.detail(p))
                        } trailing: {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(purchases.monthlyPrice(p)).font(.rounded(.title2)).foregroundStyle(Theme.text)
                                Text("a month").font(.footnote).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
                .padding(.top, 16)

                Button {
                    Task {
                        await purchases.purchase(plan)
                        if purchases.hasPlus { dismiss() }
                    }
                } label: {
                    if purchases.isPurchasing { ProgressView().tint(Theme.onPrimary) } else { Text(purchases.cta(plan)) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(purchases.isPurchasing)
                .accessibilityLabel(purchases.isPurchasing ? "Purchasing" : purchases.cta(plan))
                .padding(.top, 16)

                Text(purchases.terms(plan))
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)

                // Side by side when they fit, stacked at large text sizes.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) { links }
                    VStack(spacing: 0) { links }
                }
                .buttonStyle(TextButtonStyle(font: .footnote))
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            if let home = model.home { position = .home(home, radius: 900, sheetFraction: 0.55) }
        }
        .alert("Unwalked Plus", isPresented: Binding(
            get: { purchases.errorMessage != nil },
            set: { if !$0 { purchases.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(purchases.errorMessage ?? "")
        }
    }

    @ViewBuilder private var links: some View {
        Button("Restore purchases") {
            Task {
                await purchases.restore()
                if purchases.hasPlus { dismiss() }
            }
        }
        Button("Terms") { openURL(Links.terms) }
        if let privacy = Links.privacy {
            Button("Privacy") { openURL(privacy) }
        }
    }
}

enum Links {
    /// Apple's standard End User Licence Agreement. Unwalked uses it unchanged.
    static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    /// `PrivacyPolicyURL` in Info.plist, served by the Worker in `server/` at `/privacy`.
    /// App Review turns down a subscription paywall whose privacy link does not work, so this
    /// has to point at a live page before a build is uploaded.
    static let privacy: URL? = {
        guard let set = Bundle.main.object(forInfoDictionaryKey: "PrivacyPolicyURL") as? String,
              !set.isEmpty, let url = URL(string: set)
        else {
            assertionFailure("PrivacyPolicyURL is empty. Set it in project.yml, then run xcodegen.")
            return nil
        }
        return url
    }()
}
