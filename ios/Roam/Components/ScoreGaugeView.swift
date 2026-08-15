import SwiftUI

struct ScoreGaugeView: View {
    @ObservedObject private var theme = ThemeManager.shared
    let score: Double
    let label: DifficultyLabel

    @State private var animatedProgress: Double = 0
    @State private var hasAppeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var progress: Double {
        min(max(score / 10.0, 0), 1)
    }

    private var accentColor: Color {
        label.color
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(AppDesign.cardStrokeStrong, lineWidth: 14)

            Circle()
                .trim(from: 0, to: animatedProgress)
                .stroke(
                    accentColor,
                    style: StrokeStyle(lineWidth: 14, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            VStack(spacing: 2) {
                KineticMetricText(
                    value: String(format: "%.1f", score),
                    fontSize: 64,
                    foreground: AppDesign.Ink.primary,
                    context: .routeResult
                )

                Text("OUT OF 10")
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(AppDesign.Ink.tertiary)
            }
            .scaleEffect(hasAppeared ? 1 : 0.95)
            .opacity(hasAppeared ? 1 : 0)
        }
        .frame(width: 204, height: 204)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.25) : AppAnimation.reveal) {
                animatedProgress = progress
                hasAppeared = true
            }
        }
        .onChange(of: progress) { _, newValue in
            withAnimation(AppAnimation.spring) {
                animatedProgress = newValue
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Difficulty score \(String(format: "%.1f", score)) out of 10, \(label.rawValue)")
    }
}

#Preview {
    ScoreGaugeView(score: 4.2, label: .easy)
        .padding()
}
