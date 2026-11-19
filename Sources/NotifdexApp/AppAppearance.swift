#if os(macOS)
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case glass
    case standard

    var id: Self { self }

    var title: String {
        switch self {
        case .glass: "Glass"
        case .standard: "Standard"
        }
    }
}

private struct AppAppearanceKey: EnvironmentKey {
    static let defaultValue: AppAppearance = .standard
}

extension EnvironmentValues {
    var notifdexAppearance: AppAppearance {
        get { self[AppAppearanceKey.self] }
        set { self[AppAppearanceKey.self] = newValue }
    }
}

enum AppearanceSurface: Equatable {
    case window
    case list
    case detail
}

extension View {
    func notifdexSurface(_ surface: AppearanceSurface) -> some View {
        modifier(AppSurfaceModifier(surface: surface))
    }
}

private struct AppSurfaceModifier: ViewModifier {
    let surface: AppearanceSurface

    @Environment(\.notifdexAppearance) private var appearance
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var usesGlass: Bool {
        appearance == .glass && !reduceTransparency && contrast != .increased
    }

    func body(content: Content) -> some View {
        // Switch the decoration in place so the content and its view state keep
        // the same identity when appearance or accessibility settings change.
        content
            .scrollContentBackground(usesGlass && surface == .list ? .hidden : .automatic)
            .background(alignment: .center) {
                if usesGlass {
                    glassBackground
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }

    @ViewBuilder private var glassBackground: some View {
        let palette = GlassPalette(dark: colorScheme == .dark)
        switch surface {
        case .window:
            LinearGradient(colors: palette.window, startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
        case .list, .detail:
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            shape
                .fill(.regularMaterial)
                .overlay {
                    shape.fill(LinearGradient(
                        colors: palette.panel,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                }
                .overlay {
                    shape.strokeBorder(LinearGradient(
                        colors: palette.edge,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                }
        }
    }
}

private struct GlassPalette {
    let window: [Color]
    let panel: [Color]
    let edge: [Color]

    init(dark: Bool) {
        if dark {
            window = [
                Color(red: 0.17, green: 0.15, blue: 0.26),
                Color(red: 0.08, green: 0.10, blue: 0.16),
                Color(red: 0.09, green: 0.18, blue: 0.23)
            ]
            panel = [Color(red: 0.64, green: 0.59, blue: 0.90).opacity(0.17), .clear]
            edge = [.white.opacity(0.23), Color(red: 0.55, green: 0.68, blue: 0.87).opacity(0.13)]
        } else {
            window = [
                Color(red: 0.91, green: 0.89, blue: 0.98),
                Color(red: 0.96, green: 0.96, blue: 0.99),
                Color(red: 0.87, green: 0.94, blue: 0.97)
            ]
            panel = [.white.opacity(0.48), Color(red: 0.73, green: 0.75, blue: 0.93).opacity(0.20)]
            edge = [.white.opacity(0.88), Color(red: 0.38, green: 0.40, blue: 0.59).opacity(0.25)]
        }
    }
}
#endif
