import SwiftUI
import UIKit

struct ClipConnectOverlay: View {
    @ObservedObject var ble = ClipBLE.shared
    @State private var visible = false

    var body: some View {
        ZStack(alignment: .bottom) {
            if visible {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { hide() }
                    .transition(.opacity)

                ClipConnectCard(state: ble.state, battery: ble.battery,
                                onDone: hide,
                                onCancel: { ble.disconnect(); hide() })
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .allowsHitTesting(visible)
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: visible)
        .onChange(of: ble.state) { _, new in
            switch new {
            case .scanning, .connecting:
                visible = true
            case .connected:
                visible = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if ble.state == .connected { hide() }
                }
            default:
                break
            }
        }
    }

    private func hide() { visible = false }
}

struct ClipConnectCard: View {
    let state: ClipBLE.State
    let battery: Int?
    let onDone: () -> Void
    let onCancel: () -> Void

    private var connected: Bool { state == .connected }

    private var title: String {
        switch state {
        case .connected: return "Clip"
        case .connecting: return "Connecting…"
        default: return "Looking for your Clip"
        }
    }

    private var batteryIcon: String {
        guard let b = battery else { return "battery.100" }
        switch b {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Spacer()
                Button {
                    connected ? onDone() : onCancel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(.quaternary, in: Circle())
                }
            }

            Text(title)
                .font(.title2.bold())
                .contentTransition(.opacity)

            ZStack {
                if !connected { PulseRings() }
                ClipModel(glow: connected ? .green : .blue, pulsing: !connected)
                    .frame(width: 170, height: 115)
                if connected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .green)
                        .shadow(color: .green.opacity(0.4), radius: 8)
                        .offset(x: 72, y: 52)
                        .transition(.scale(scale: 0.2).combined(with: .opacity))
                }
            }
            .frame(height: 200)

            if connected {
                HStack(spacing: 6) {
                    Image(systemName: batteryIcon).foregroundStyle(.green)
                    Text(battery.map { "\($0)%" } ?? "Connected")
                        .font(.headline)
                        .monospacedDigit()
                }
                .transition(.opacity)

                Button(action: onDone) {
                    Text("Done")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(.green)
                .transition(.opacity)
            } else {
                Text("Keep the clip close to your phone")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ProgressView()
                    .padding(.bottom, 8)
            }
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 38, style: .continuous))
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: connected)
    }
}

struct ClipModel: View {
    let glow: Color
    let pulsing: Bool
    @State private var float = false
    @State private var bright = false

    var body: some View {
        ZStack {
            Ellipse()
                .fill(.black.opacity(0.18))
                .frame(width: 130, height: 16)
                .blur(radius: 8)
                .scaleEffect(float ? 0.85 : 1)
                .offset(y: 78)

            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.99), Color(white: 0.84)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(.white.opacity(0.9), lineWidth: 1.5)
                    )
                    .shadow(color: .black.opacity(0.2), radius: 14, y: 10)

                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
                    .padding(9)

                Circle()
                    .fill(glow)
                    .frame(width: 18, height: 18)
                    .blur(radius: 6)
                    .opacity(pulsing ? (bright ? 1 : 0.3) : 1)
                    .offset(x: -50)

                Circle()
                    .fill(glow.opacity(0.9))
                    .frame(width: 7, height: 7)
                    .opacity(pulsing ? (bright ? 1 : 0.5) : 1)
                    .offset(x: -50)

                Capsule()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: 4, height: 24)
                    .offset(x: -83)
            }
            .rotation3DEffect(.degrees(float ? 10 : -10), axis: (x: 1, y: 0.3, z: 0), perspective: 0.6)
            .offset(y: float ? -6 : 4)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { float = true }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { bright = true }
        }
    }
}

struct PulseRings: View {
    @State private var go = false

    var body: some View {
        ZStack {
            ForEach(0..<3) { i in
                Circle()
                    .stroke(Color.blue.opacity(0.35), lineWidth: 2)
                    .frame(width: 140, height: 140)
                    .scaleEffect(go ? 1.6 : 0.6)
                    .opacity(go ? 0 : 1)
                    .animation(.easeOut(duration: 2.4).repeatForever(autoreverses: false).delay(Double(i) * 0.8),
                               value: go)
            }
        }
        .onAppear { go = true }
    }
}
