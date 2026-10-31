import SwiftUI

/// Custom vector brand logo for ExtDisplay, matching the macOS & iOS AppIcon artwork:
/// A rich midnight-to-cyan squircle badge featuring a Mac monitor seamlessly extending
/// into a glowing cyan iPad display with a directional bridge arrow.
public struct ExtDisplayLogoView: View {
    public var size: CGFloat

    public init(size: CGFloat = 48) {
        self.size = size
    }

    public var body: some View {
        let s = size / 100.0
        ZStack {
            // Squircle Background
            RoundedRectangle(cornerRadius: 22.5 * s, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.04, green: 0.07, blue: 0.16),
                            Color(red: 0.08, green: 0.20, blue: 0.44),
                            Color(red: 0.05, green: 0.45, blue: 0.72)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    // Subtle radial cyan glow in bottom-right
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.cyan.opacity(0.45),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: 48 * s
                            )
                        )
                        .frame(width: 90 * s, height: 90 * s)
                        .offset(x: 16 * s, y: 18 * s)
                        .clipShape(RoundedRectangle(cornerRadius: 22.5 * s, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22.5 * s, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.32),
                                    Color.cyan.opacity(0.25),
                                    Color.white.opacity(0.08)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: max(1.0, 1.8 * s)
                        )
                )
                .shadow(color: Color.cyan.opacity(0.28), radius: 8 * s, x: 0, y: 4 * s)

            // Back Display (Mac Monitor)
            ZStack {
                // Monitor stand neck & base
                Path { path in
                    path.move(to: CGPoint(x: 34.5 * s, y: 63 * s))
                    path.addLine(to: CGPoint(x: 43.5 * s, y: 63 * s))
                    path.addLine(to: CGPoint(x: 45.5 * s, y: 71 * s))
                    path.addLine(to: CGPoint(x: 32.5 * s, y: 71 * s))
                    path.closeSubpath()
                }
                .fill(Color.white.opacity(0.45))

                Capsule()
                    .fill(Color.white.opacity(0.65))
                    .frame(width: 24 * s, height: 3.2 * s)
                    .position(x: 39 * s, y: 71.5 * s)

                // Monitor screen body
                RoundedRectangle(cornerRadius: 5.5 * s, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.14, green: 0.29, blue: 0.62),
                                Color(red: 0.08, green: 0.17, blue: 0.38)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5.5 * s, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.78), lineWidth: max(1.0, 2.2 * s))
                    )
                    .frame(width: 50 * s, height: 36 * s)
                    .position(x: 39 * s, y: 44 * s)
            }

            // Front Display (iPad Extended Screen)
            ZStack {
                RoundedRectangle(cornerRadius: 6 * s, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.0, green: 0.90, blue: 1.0),
                                Color(red: 0.12, green: 0.52, blue: 0.96)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6 * s, style: .continuous)
                            .strokeBorder(Color.white, lineWidth: max(1.2, 2.5 * s))
                    )
                    .shadow(color: Color.black.opacity(0.38), radius: 5 * s, x: -2 * s, y: 2 * s)
                    .frame(width: 44 * s, height: 32 * s)
                    .position(x: 64 * s, y: 56 * s)

                // Bridge Arrow (Mac -> iPad)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 16 * s, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: Color.black.opacity(0.25), radius: 2 * s, x: 0, y: 1 * s)
                    .position(x: 63 * s, y: 55.5 * s)
            }
        }
        .frame(width: size, height: size)
    }
}

