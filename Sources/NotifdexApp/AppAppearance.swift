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
    case inboxList
    case detail
    case inspector
}

extension View {
    func notifdexAlertSelection(_ selected: Bool) -> some View {
        modifier(AlertSelectionTint(selected: selected))
    }

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

    private var hidesScrollBackground: Bool {
        usesGlass && (surface == .list || surface == .inboxList)
    }

    func body(content: Content) -> some View {
        // Switch the decoration in place so the content and its view state keep
        // the same identity when appearance or accessibility settings change.
        content
            .scrollContentBackground(hidesScrollBackground ? .hidden : .automatic)
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
            VioletBackdrop(palette: palette)
                .ignoresSafeArea()
        case .inboxList:
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            shape.fill(palette.inbox)
                .overlay { shape.strokeBorder(palette.inboxBorder) }
        case .list, .detail, .inspector:
            let isInspector = surface == .inspector
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            shape.fill(.regularMaterial)
                .overlay {
                    shape.fill(LinearGradient(
                        colors: isInspector ? palette.inspector : palette.panel,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                }
                .overlay {
                    shape.strokeBorder(LinearGradient(
                        colors: isInspector ? palette.inspectorEdge : palette.edge,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .padding(isInspector ? 1 : 0)
                }
                .overlay {
                    if isInspector {
                        shape.inset(by: 3).strokeBorder(palette.inspectorInset)
                    }
                }
                .shadow(color: .black.opacity(isInspector ? 0.20 : 0), radius: 14, y: 6)
        }
    }
}

private struct AlertSelectionTint: ViewModifier {
    let selected: Bool

    @Environment(\.notifdexAppearance) private var appearance
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.background {
            if selected && appearance == .glass && !reduceTransparency && contrast != .increased {
                let tint = colorScheme == .dark
                    ? Color(red: 0.73, green: 0.57, blue: 0.96)
                    : Color(red: 0.50, green: 0.30, blue: 0.81)
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tint.opacity(0.11))
                    .padding(.horizontal, -5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct VioletBackdrop: View {
    let palette: GlassPalette

    var body: some View {
        let highlight = LinearGradient(
            colors: palette.foldHighlight,
            startPoint: .topTrailing,
            endPoint: .bottomLeading
        )
        ZStack {
            LinearGradient(colors: palette.window, startPoint: .topLeading, endPoint: .bottomTrailing)
            VioletFold()
                .stroke(palette.foldShade, lineWidth: 100)
                .blur(radius: 24)
            VioletFold()
                .stroke(highlight, lineWidth: 31)
                .blur(radius: 10)
            VioletFold()
                .stroke(highlight, lineWidth: 2)
                .blur(radius: 1)
        }
        .clipped()
    }
}

private struct VioletFold: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: point(0.54, -0.15))
        path.addCurve(to: point(0.96, 0.33), control1: point(0.69, 0.17), control2: point(1.03, -0.02))
        path.addCurve(to: point(1.02, 1.09), control1: point(0.89, 0.59), control2: point(0.84, 0.73))
        return path
    }
}

private struct GlassPalette {
    let window: [Color]
    let panel: [Color]
    let edge: [Color]
    let inbox: Color
    let inboxBorder: Color
    let inspector: [Color]
    let inspectorEdge: [Color]
    let inspectorInset: Color
    let foldShade: Color
    let foldHighlight: [Color]

    init(dark: Bool) {
        if dark {
            window = [
                Color(red: 0.28, green: 0.17, blue: 0.42),
                Color(red: 0.13, green: 0.09, blue: 0.21),
                Color(red: 0.30, green: 0.17, blue: 0.42)
            ]
            panel = [Color(red: 0.64, green: 0.59, blue: 0.90).opacity(0.17), .clear]
            edge = [.white.opacity(0.23), Color(red: 0.55, green: 0.68, blue: 0.87).opacity(0.13)]
            inbox = Color(red: 0.10, green: 0.09, blue: 0.15)
            inboxBorder = .white.opacity(0.13)
            inspector = [
                Color(red: 0.55, green: 0.38, blue: 0.76).opacity(0.24),
                Color(red: 0.15, green: 0.09, blue: 0.25).opacity(0.42)
            ]
            inspectorEdge = [
                Color(red: 0.90, green: 0.80, blue: 1.0).opacity(0.75),
                Color(red: 0.75, green: 0.64, blue: 0.91).opacity(0.25),
                Color(red: 0.74, green: 0.58, blue: 0.96).opacity(0.53)
            ]
            inspectorInset = .white.opacity(0.10)
            foldShade = Color(red: 0.12, green: 0.03, blue: 0.27).opacity(0.73)
            foldHighlight = [.white.opacity(0.51), Color(red: 0.76, green: 0.52, blue: 0.97).opacity(0.29), .clear]
        } else {
            window = [
                Color(red: 0.88, green: 0.82, blue: 0.96),
                Color(red: 0.96, green: 0.93, blue: 0.99),
                Color(red: 0.81, green: 0.72, blue: 0.94)
            ]
            panel = [.white.opacity(0.48), Color(red: 0.73, green: 0.75, blue: 0.93).opacity(0.20)]
            edge = [.white.opacity(0.88), Color(red: 0.38, green: 0.40, blue: 0.59).opacity(0.25)]
            inbox = Color(red: 0.97, green: 0.95, blue: 0.99)
            inboxBorder = Color(red: 0.39, green: 0.28, blue: 0.58).opacity(0.26)
            inspector = [.white.opacity(0.61), Color(red: 0.78, green: 0.66, blue: 0.92).opacity(0.36)]
            inspectorEdge = [.white, inboxBorder, .white.opacity(0.83)]
            inspectorInset = Color(red: 0.37, green: 0.24, blue: 0.55).opacity(0.14)
            foldShade = Color(red: 0.62, green: 0.43, blue: 0.80).opacity(0.38)
            foldHighlight = [.white.opacity(0.92), .white.opacity(0.47), .clear]
        }
    }
}
#endif
