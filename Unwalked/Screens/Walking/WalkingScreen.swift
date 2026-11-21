import MapKit
import SwiftUI

/// Walking, Off the loop and Running late from the v2 designs, plus the Report a street sheet.
struct WalkingScreen: View {
    @Environment(AppModel.self) private var model
    let session: WalkSession

    @State private var position: MapCameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
    @State private var reporting = false
    @State private var resizing = false

    var body: some View {
        ZStack(alignment: .bottom) {
            UnwalkedMap(layers: layers, position: $position)

            VStack(alignment: .leading, spacing: 12) {
                TurnCard(symbol: session.symbol, title: session.headline, subtitle: session.detail)
                    .animation(.snappy, value: session.headline)
                if let off = session.offRoute {
                    Text("You passed your turn. Home about \(off.minutesLate) minute\(off.minutesLate == 1 ? "" : "s") late.")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .frame(minHeight: 36)
                        .glass(radius: 18)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if session.isRerouting {
                    Label("Finding a new way…", systemImage: "arrow.triangle.branch")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .frame(minHeight: 36)
                        .glass(radius: 18)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .animation(.snappy, value: session.offRoute)

            if reporting {
                ReportSheet(session: session) { reporting = false }
                    .transition(.move(edge: .bottom))
            } else {
                VStack(spacing: 12) {
                    if let offer = session.lateOffer {
                        LateCard(offer: offer, session: session)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if resizing {
                        ResizeCard(session: session) { resizing = false }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    WalkToolbar(session: session, onReport: { withAnimation(.snappy) { reporting = true } },
                                onResize: {
                                    // Changing a walk part-way round is part of Plus.
                                    if model.purchases.hasPlus { resizing.toggle() } else { model.showPaywall = true }
                                },
                                onEnd: { model.endWalk() })
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .animation(.snappy, value: session.lateOffer)
                .animation(.snappy, value: resizing)
            }
        }
        .animation(.snappy, value: reporting)
        .onChange(of: session.hasArrived) { _, arrived in
            if arrived { model.endWalk() }
        }
        .onChange(of: reporting) { _, isReporting in
            if isReporting {
                withAnimation { position = .fitting(session.stretchAhead, sheetFraction: 0.5, padding: 4) }
            } else {
                position = .userLocation(followsHeading: true, fallback: .automatic)
            }
        }
    }

    private var layers: MapLayers {
        var l = MapLayers(
            walked: model.library.walkedPaths + [session.trail],
            ahead: session.pathAhead,
            fresh: session.newAhead,
            home: session.route.home,
            showsUser: true
        )
        if let offer = session.lateOffer { l.shortcut = offer.shortcut.path }
        if reporting { l.reported = session.stretchAhead }
        return l
    }
}

struct WalkToolbar: View {
    let session: WalkSession
    let onReport: () -> Void
    /// Called when the walker taps the time left, to make the walk shorter or longer.
    var onResize: () -> Void = {}
    /// Called once the walker confirms ending the walk.
    let onEnd: () -> Void
    @State private var confirmEnd = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onResize) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Text("\(session.minutesLeft) min left")
                            .font(.rounded(.title2))
                            .foregroundStyle(Theme.text)
                            .contentTransition(.numericText())
                        Image(systemName: "plusminus")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.muted)
                            .accessibilityHidden(true)
                    }
                    Text(session.statusLine)
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Makes this walk shorter or longer")

            // Three bare icons had to be learned. Ending the walk stays out; the rest have names.
            Menu {
                Button("Report a street", systemImage: "flag", action: onReport)
                Button("Head home", systemImage: "house") { Task { await session.headHome() } }
                    .disabled(session.isHeadingHome)
                Button("Shorter or longer", systemImage: "plusminus", action: onResize)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Theme.controlTint))
            }
            .accessibilityLabel("More")
            RoundIconButton(systemName: "stop.fill", label: "End walk", fill: Theme.controlTint) { confirmEnd = true }
                // Anchored to the button so the popover opens beside it, not at the top of the screen.
                .confirmationDialog("End this walk?", isPresented: $confirmEnd, titleVisibility: .visible) {
                    Button("End walk", action: onEnd)
                    Button("Keep walking", role: .cancel) {}
                }
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 72)
        .glass(radius: 28)
    }
}

/// Shorter or longer, part-way round (F13).
struct ResizeCard: View {
    let session: WalkSession
    let onClose: () -> Void
    @State private var failed: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Change this walk")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.text)
            Text(failed ?? "Plans a new way home from where you are now.")
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            HStack(spacing: 8) {
                Button("\(WalkSession.resizeStep) min shorter") { change(by: -WalkSession.resizeStep) }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!session.canShorten)
                    .opacity(session.canShorten ? 1 : 0.45)
                Button("\(WalkSession.resizeStep) min longer") { change(by: WalkSession.resizeStep) }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .disabled(session.isRerouting)
            .padding(.top, 14)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Theme.sheet)
                .shadow(color: Palette.ink.opacity(0.16), radius: 12, y: 8)
        )
    }

    private func change(by minutes: Int) {
        failed = nil
        Task {
            if await session.resize(by: minutes) != nil {
                onClose()
            } else {
                failed = minutes > 0 ? "Couldn't find a longer way home from here." : "Couldn't find a shorter way home from here."
            }
        }
    }
}

struct LateCard: View {
    let offer: WalkSession.LateOffer
    let session: WalkSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("You will be home about \(offer.minutesLate) minutes late")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.text)
            Text(offer.summary)
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
                .padding(.top, 4)
            HStack(spacing: 8) {
                Button("Take the shortcut") { session.takeShortcut() }
                    .buttonStyle(PrimaryButtonStyle(height: 48, font: .subheadline))
                Button("Keep my loop") { session.keepLoop() }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.top, 14)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Theme.sheet)
                .shadow(color: Palette.ink.opacity(0.16), radius: 12, y: 8)
        )
    }
}

struct ReportSheet: View {
    let session: WalkSession
    let onClose: () -> Void
    @State private var reason: ReportReason = .blocked

    var body: some View {
        BottomSheet {
            HStack(alignment: .top) {
                SheetTitle(text: "What is wrong with this street?")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Theme.chip))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel report")
                .padding(.top, -6)
            }
            .padding(.top, 16)
            BodyText(text: "The stretch just ahead of you, marked in red").padding(.top, 4)

            VStack(spacing: 8) {
                ForEach(ReportReason.allCases) { r in
                    ChoiceRow(isSelected: reason == r, height: 56, radius: 18, action: { reason = r }) {
                        Image(systemName: r.symbol)
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .frame(width: 22)
                            .accessibilityHidden(true)
                        Text(r.label)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.text)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } trailing: {
                        RadioDot(isOn: reason == r)
                    }
                }
            }
            .padding(.top, 16)

            Text("You will be routed round it now and never sent here again.")
                .font(.footnote)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            Button("Report and reroute") {
                let picked = reason
                onClose()
                Task { await session.report(picked) }
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.top, 16)
        }
        // Keeps VoiceOver inside the sheet while it is open.
        .accessibilityAddTraits(.isModal)
    }
}
