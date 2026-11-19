import MapKit
import SwiftUI

/// Walking, Off the loop and Running late from the v2 designs, plus the Report a street sheet.
struct WalkingScreen: View {
    @Environment(AppModel.self) private var model
    let session: WalkSession

    @State private var position: MapCameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
    @State private var reporting = false
    @State private var confirmEnd = false

    var body: some View {
        ZStack(alignment: .bottom) {
            UnwalkedMap(layers: layers, position: $position)

            VStack(alignment: .leading, spacing: 12) {
                TurnCard(symbol: session.symbol, title: session.headline, subtitle: session.detail)
                    .animation(.snappy, value: session.headline)
                if let off = session.offRoute {
                    Text("You passed your turn. Home about \(off.minutesLate) minute\(off.minutesLate == 1 ? "" : "s") late.")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .glass(radius: 18)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if session.isRerouting {
                    Label("Finding a new way…", systemImage: "arrow.triangle.branch")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14)
                        .frame(height: 36)
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
                    WalkToolbar(session: session, onReport: { withAnimation(.snappy) { reporting = true } },
                                onEnd: { confirmEnd = true })
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .animation(.snappy, value: session.lateOffer)
            }
        }
        .animation(.snappy, value: reporting)
        .confirmationDialog("End this walk?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End walk") { model.endWalk() }
            Button("Keep walking", role: .cancel) {}
        } message: {
            Text("The streets you have walked so far still count.")
        }
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
            walked: model.library.walks.map(\.path) + [session.trail],
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
    let onEnd: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(session.minutesLeft) min left")
                    .font(.rounded(22))
                    .foregroundStyle(Theme.text)
                    .contentTransition(.numericText())
                Text(session.statusLine)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            RoundIconButton(systemName: "flag", label: "Report a problem with this street",
                            fill: Theme.controlTint, action: onReport)
            RoundIconButton(systemName: "house", label: "Head home by the shortest way", fill: Theme.controlTint) {
                Task { await session.headHome() }
            }
            .disabled(session.isHeadingHome)
            RoundIconButton(systemName: "stop.fill", label: "End walk", fill: Theme.controlTint, action: onEnd)
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .frame(height: 72)
        .glass(radius: 28)
    }
}

struct LateCard: View {
    let offer: WalkSession.LateOffer
    let session: WalkSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("You will be home about \(offer.minutesLate) minutes late")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text(offer.summary)
                .font(.system(size: 15))
                .foregroundStyle(Theme.muted)
                .padding(.top, 4)
            HStack(spacing: 8) {
                Button("Take the shortcut") { session.takeShortcut() }
                    .buttonStyle(PrimaryButtonStyle(height: 48, fontSize: 15))
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
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } trailing: {
                        RadioDot(isOn: reason == r)
                    }
                }
            }
            .padding(.top, 16)

            Text("You will be routed round it now and never sent here again.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .padding(.top, 12)

            Button("Report and reroute") {
                let picked = reason
                onClose()
                Task { await session.report(picked) }
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.top, 16)
        }
    }
}
