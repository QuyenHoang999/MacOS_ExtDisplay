import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject var model: ClientModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            DisplayView()

            if case .streaming = model.state {
                EmptyView()
            } else {
                WaitingView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.state)
    }
}

// MARK: - Minimal Auto-Connect Waiting Screen

private struct WaitingView: View {
    @EnvironmentObject var model: ClientModel

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.06, blue: 0.12),
                    Color(red: 0.01, green: 0.02, blue: 0.05),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                ExtDisplayLogoView(size: 92)

                VStack(spacing: 10) {
                    Text("ExtDisplay")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    StatusPill(
                        text: model.state == .connected ? "Connecting over USB-C…" : "Auto-Connecting via USB-C…",
                        color: model.state == .connected ? .orange : .cyan
                    )
                }

                TransportBadge(icon: "cable.connector", title: "USB-C Auto-Connect")
                    .padding(.top, 4)
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 34)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                    )
            )
            .padding(24)
        }
    }
}

private struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(color.opacity(0.16), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(color.opacity(0.35), lineWidth: 1)
        )
    }
}

private struct TransportBadge: View {
    let icon: String
    let title: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(.white.opacity(0.65))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.white.opacity(0.06), in: Capsule())
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView().environmentObject(ClientModel())
    }
}
