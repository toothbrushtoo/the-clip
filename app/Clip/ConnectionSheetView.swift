import SwiftUI
import UIKit

// MARK: - Presenting the card

// Shows the connection card over the whole app. From any screen, call
// `ConnectionSheet.shared.present()` right before starting the Bluetooth connection.
final class ConnectionSheet: ObservableObject {
    static let shared = ConnectionSheet()

    @Published var isPresented = false

    func present() {
        ClipBLE.shared.interactive = true
        withAnimation(Self.showAnimation) { isPresented = true }
    }

    func dismiss() {
        withAnimation(Self.hideAnimation) { isPresented = false }
        ClipBLE.shared.interactive = false
        if ClipBLE.shared.state != .connected { ClipBLE.shared.disconnect() }
    }

    private static var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    private static var showAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.74)
    }

    private static var hideAnimation: Animation {
        reduceMotion ? .easeIn(duration: 0.15) : .spring(response: 0.35, dampingFraction: 1)
    }
}

// Lives in ContentView's overlay so the card and the dimmed background cover the tab bar too.
struct ConnectionSheetHost: View {
    @ObservedObject private var sheet = ConnectionSheet.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            if sheet.isPresented {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(Color.black.opacity(0.28))
                    .ignoresSafeArea()
                    .onTapGesture { sheet.dismiss() }
                    .transition(.opacity)

                ConnectionCard()
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea(.container, edges: .bottom)
        .allowsHitTesting(sheet.isPresented)
    }
}

// MARK: - The card

struct ConnectionCard: View {
    @ObservedObject private var ble = ClipBLE.shared
    @ObservedObject private var sheet = ConnectionSheet.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Phase { case searching, found, connecting, connected, failed }

    @State private var phase: Phase = .searching
    @State private var searchAmount: Double = 1
    @State private var boardScale: CGFloat = 0.9
    @State private var led: XiaoBoard.LED = .off
    @State private var glow: Double = 0
    @State private var checkShown = false
    @State private var checkProgress: CGFloat = 0
    @State private var shakes: CGFloat = 0
    @State private var blinkTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            illustration
                .frame(height: 220)
            footer
                .frame(height: 140)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 30)
        .background {
            RoundedRectangle(cornerRadius: 40, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
        }
        .onChange(of: ble.state, initial: true) { _, state in apply(state) }
        .onDisappear { blinkTask?.cancel() }
    }

    private var header: some View {
        ZStack {
            Text("Clip")
                .font(.system(.title2, design: .rounded, weight: .bold))
            HStack {
                Spacer()
                Button {
                    sheet.dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
        }
    }

    private var illustration: some View {
        TimelineView(.animation(paused: reduceMotion || searchAmount == 0)) { context in
            scene(at: context.date.timeIntervalSinceReferenceDate)
        }
    }

    private func scene(at t: Double) -> some View {
        ZStack {
            SearchRings(time: t)
                .opacity(searchAmount)
            board(time: t)
        }
    }

    private func board(time t: Double) -> some View {
        let bob = reduceMotion ? 0 : sin(t * 1.5) * 6 * searchAmount
        let tilt = reduceMotion ? 0 : sin(t * 1.5 + 0.9) * 5 * searchAmount
        return XiaoBoard(led: led)
            .frame(width: 150, height: 128)
            .rotation3DEffect(.degrees(tilt), axis: (x: 1, y: 0.25, z: 0), perspective: 0.7)
            .offset(y: bob)
            .scaleEffect(boardScale)
            .shadow(color: Color.green.opacity(glow * 0.55), radius: 26)
            .overlay(alignment: .bottomTrailing) {
                checkBadge.offset(x: 14, y: 10)
            }
            .modifier(Shake(animatableData: shakes))
    }

    private var checkBadge: some View {
        ZStack {
            Circle()
                .fill(Color.green)
                .frame(width: 44, height: 44)
                .overlay(Circle().stroke(Color(uiColor: .secondarySystemGroupedBackground), lineWidth: 3))
            CheckShape()
                .trim(from: 0, to: checkProgress)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                .frame(width: 22, height: 22)
        }
        .scaleEffect(checkShown ? 1 : 0.3)
        .opacity(checkShown ? 1 : 0)
    }

    private var footer: some View {
        VStack(spacing: 14) {
            status
                .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            buttons
        }
    }

    @ViewBuilder private var status: some View {
        switch phase {
        case .searching:
            Text("Searching…")
                .font(.system(.body, design: .rounded, weight: .medium))
                .foregroundStyle(.secondary)
                .transition(fade)
        case .found:
            EmptyView()
        case .connecting:
            Text("Connecting…")
                .font(.system(.body, design: .rounded, weight: .medium))
                .foregroundStyle(.secondary)
                .transition(fade)
        case .connected:
            HStack(spacing: 28) {
                batteryCell
                signalCell
            }
            .transition(fade)
        case .failed:
            VStack(spacing: 4) {
                Text(ble.failure?.title ?? "Couldn't connect")
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                Text(ble.failure?.hint ?? "Try again.")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .transition(fade)
        }
    }

    @ViewBuilder private var buttons: some View {
        if phase == .found || phase == .connecting {
            PillButton(title: "Connect", loading: phase == .connecting) { ble.connectFound() }
                .transition(fade)
        } else if phase == .connected {
            PillButton(title: "Done") { sheet.dismiss() }
                .transition(fade)
        } else if phase == .failed {
            PillButton(title: "Try Again") { ble.connect() }
                .transition(fade)
        } else {
            Color.clear.frame(height: 52)
        }
    }

    private var batteryCell: some View {
        HStack(spacing: 8) {
            BatteryGlyph(percent: ble.battery)
            Text(ble.battery.map { "\($0)%" } ?? "—")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
    }

    private var signalCell: some View {
        HStack(spacing: 8) {
            Image(systemName: "cellularbars", variableValue: signalLevel)
                .font(.title3)
            Text(signalLabel)
                .font(.system(.title3, design: .rounded, weight: .semibold))
        }
    }

    private var signalLevel: Double {
        guard let r = ble.rssi else { return 0 }
        switch r {
        case (-60)...: return 1
        case (-70)...: return 0.75
        case (-80)...: return 0.5
        default: return 0.25
        }
    }

    private var signalLabel: String {
        guard let r = ble.rssi else { return "—" }
        switch r {
        case (-60)...: return "Strong"
        case (-70)...: return "Good"
        case (-80)...: return "Fair"
        default: return "Weak"
        }
    }

    private var fade: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96))
    }

    // Everything the card shows comes from the real Bluetooth state. This maps it to a phase
    // and runs the one-off effects for the change: haptics, the LED blink, the checkmark, the shake.
    private func apply(_ state: ClipBLE.State) {
        let new: Phase
        switch state {
        case .found: new = .found
        case .connecting: new = .connecting
        case .connected: new = .connected
        case .failed: new = .failed
        default: new = .searching
        }
        guard new != phase else { return }

        blinkTask?.cancel()
        let anim: Animation = reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.82)
        withAnimation(anim) {
            phase = new
            searchAmount = new == .searching ? 1 : 0
            glow = new == .connected ? 1 : 0
            if new != .connected {
                checkShown = false
                checkProgress = 0
            }
        }

        switch new {
        case .searching:
            led = .off
            withAnimation(anim) { boardScale = 0.9 }
        case .found:
            led = .off
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(reduceMotion ? anim : .spring(response: 0.45, dampingFraction: 0.5)) { boardScale = 1 }
        case .connecting:
            withAnimation(anim) { boardScale = 1 }
            blinkBlue()
        case .connected:
            led = .green
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(anim) { boardScale = 1 }
            if reduceMotion {
                checkShown = true
                checkProgress = 1
            } else {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.6).delay(0.1)) { checkShown = true }
                withAnimation(.easeOut(duration: 0.45).delay(0.3)) { checkProgress = 1 }
            }
        case .failed:
            led = .off
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            withAnimation(anim) { boardScale = 1 }
            if !reduceMotion {
                withAnimation(.easeInOut(duration: 0.55)) { shakes += 1 }
            }
        }
    }

    // The real board blinks its blue LED twice when a phone connects, so the drawing does too.
    private func blinkBlue() {
        if reduceMotion {
            led = .blue
            return
        }
        blinkTask = Task { @MainActor in
            for _ in 0..<2 {
                led = .blue
                try? await Task.sleep(for: .milliseconds(170))
                if Task.isCancelled { return }
                led = .off
                try? await Task.sleep(for: .milliseconds(170))
                if Task.isCancelled { return }
            }
            led = .blue
        }
    }
}

// MARK: - Pieces

struct PillButton: View {
    let title: String
    var loading = false
    let action: () -> Void

    var body: some View {
        GeometryReader { geo in
            Button(action: action) {
                ZStack {
                    if loading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text(title)
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: loading ? 52 : geo.size.width, height: 52)
                .background(Color.blue, in: Capsule())
            }
            .buttonStyle(PressStyle())
            .disabled(loading)
            .frame(width: geo.size.width, alignment: .center)
            .animation(.spring(response: 0.45, dampingFraction: 0.82), value: loading)
        }
        .frame(height: 52)
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct BatteryGlyph: View {
    let percent: Int?

    private var fraction: CGFloat {
        CGFloat(max(0, min(100, percent ?? 0))) / 100
    }

    private var color: Color {
        guard let percent else { return .gray }
        if percent <= 10 { return .red }
        if percent <= 20 { return .yellow }
        return .green
    }

    var body: some View {
        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.secondary.opacity(0.6), lineWidth: 1.5)
                    .frame(width: 30, height: 14)
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(color)
                    .frame(width: max(2, 25 * fraction), height: 9)
                    .padding(.leading, 2.5)
            }
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.secondary.opacity(0.6))
                .frame(width: 2, height: 5)
        }
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}

struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.minY + rect.height * 0.54))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.minY + rect.height * 0.78))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.84, y: rect.minY + rect.height * 0.26))
        return p
    }
}

// A gentle side-to-side shake that dies out. Bump `animatableData` by 1 inside withAnimation to run it.
struct Shake: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        let p = animatableData - floor(animatableData)
        let x = 9 * sin(p * .pi * 6) * (1 - p)
        return ProjectionTransform(CGAffineTransform(translationX: x, y: 0))
    }
}

struct SearchRings: View {
    let time: Double

    var body: some View {
        ZStack {
            ring(0)
            ring(1)
            ring(2)
        }
    }

    private func ring(_ i: Int) -> some View {
        let p = (time / 2.4 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
        let size = 110 + 120 * p
        return Circle()
            .stroke(Color.blue, lineWidth: 1.5)
            .frame(width: size, height: size)
            .opacity((1 - p) * 0.5)
    }
}

// The XIAO nRF52840 Sense, top down: dark board, gold pads down both sides, USB-C at the top,
// the silver radio shield in the middle, reset button on the left and the RGB LED on the right.
struct XiaoBoard: View {
    enum LED: Equatable { case off, blue, green }

    let led: LED

    private var ledColor: Color {
        switch led {
        case .off: return Color(white: 0.22)
        case .blue: return Color(red: 0.25, green: 0.55, blue: 1.0)
        case .green: return Color(red: 0.25, green: 0.9, blue: 0.45)
        }
    }

    var body: some View {
        ZStack {
            pcb
            pads
            shield
            smallParts
            resetButton
            ledView
            usbPort
        }
        .frame(width: 150, height: 128)
    }

    private var pcb: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.14, green: 0.16, blue: 0.22),
                                          Color(red: 0.06, green: 0.07, blue: 0.10)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 16, y: 10)
    }

    private var pads: some View {
        ZStack {
            ForEach(0..<7, id: \.self) { i in
                pad.offset(x: -75, y: CGFloat(i - 3) * 15)
                pad.offset(x: 75, y: CGFloat(i - 3) * 15)
            }
        }
        .frame(width: 150, height: 128)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var pad: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(LinearGradient(colors: [Color(red: 0.98, green: 0.84, blue: 0.45),
                                          Color(red: 0.80, green: 0.60, blue: 0.22)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: 10, height: 10)
            .overlay(Circle().fill(Color(red: 0.08, green: 0.09, blue: 0.12)).frame(width: 4, height: 4))
    }

    private var usbPort: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(LinearGradient(colors: [Color(white: 0.92), Color(white: 0.68)], startPoint: .top, endPoint: .bottom))
            .frame(width: 44, height: 18)
            .overlay(
                RoundedRectangle(cornerRadius: 3.5)
                    .fill(Color(white: 0.18))
                    .frame(width: 32, height: 7)
                    .offset(y: -2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.5), lineWidth: 0.8)
            )
            .offset(y: -60)
    }

    private var shield: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(LinearGradient(colors: [Color(white: 0.88), Color(white: 0.70)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 78, height: 56)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.6), lineWidth: 0.8))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color(white: 0.55).opacity(0.5))
                    .frame(width: 60, height: 3)
                    .padding(.bottom, 8)
            }
            .offset(y: 16)
    }

    private var smallParts: some View {
        ZStack {
            part(w: 7, h: 4).offset(x: -12, y: -40)
            part(w: 7, h: 4).offset(x: 0, y: -40)
            part(w: 7, h: 4).offset(x: 12, y: -40)
            part(w: 5, h: 5).offset(x: -52, y: -20)
            part(w: 5, h: 5).offset(x: 52, y: -20)
            part(w: 8, h: 8).offset(x: -52, y: 50)
        }
    }

    private func part(w: CGFloat, h: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color(white: 0.35))
            .frame(width: w, height: h)
    }

    private var resetButton: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color(white: 0.3))
            .frame(width: 10, height: 7)
            .overlay(Circle().fill(Color(white: 0.5)).frame(width: 4, height: 4))
            .offset(x: -36, y: -34)
    }

    private var ledView: some View {
        ZStack {
            Circle()
                .fill(ledColor)
                .frame(width: 26, height: 26)
                .blur(radius: 9)
                .opacity(led == .off ? 0 : 0.9)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(ledColor)
                .frame(width: 7, height: 7)
                .overlay(
                    RoundedRectangle(cornerRadius: 1.5)
                        .strokeBorder(Color.white.opacity(led == .off ? 0.15 : 0.7), lineWidth: 0.7)
                )
                .shadow(color: ledColor.opacity(led == .off ? 0 : 0.9), radius: 5)
        }
        .offset(x: 36, y: -34)
        .animation(.easeOut(duration: 0.15), value: led)
    }
}
