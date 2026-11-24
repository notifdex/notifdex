import Foundation

public enum AppSurfaceMode: String, CaseIterable, Identifiable, Sendable {
    case clearGlass
    case ambientGlass
    case customImage
    case standard

    public var id: Self { self }

    public var title: String {
        switch self {
        case .clearGlass: "Clear"
        case .ambientGlass: "Ambient"
        case .customImage: "Photo"
        case .standard: "Solid"
        }
    }

    public var subtitle: String {
        switch self {
        case .clearGlass: "See-through architectural glass"
        case .ambientGlass: "Painterly atmospheric wash"
        case .customImage: "Your image beneath frosted glass"
        case .standard: "Opaque matte finish"
        }
    }

    public var usesGlassPanels: Bool {
        self != .standard
    }
}

public enum AppThemeTier: String, CaseIterable, Identifiable, Sendable {
    case core = "Essential"
    case studio = "Atelier"

    public var id: Self { self }
}

public enum AppColorTheme: String, CaseIterable, Identifiable, Sendable {
    case mineral
    case vermilion
    case prussian
    case sienna
    case celadon
    case nocturne

    public var id: Self { self }

    public var title: String {
        switch self {
        case .mineral: "Mineral"
        case .vermilion: "Vermilion"
        case .prussian: "Prussian"
        case .sienna: "Sienna"
        case .celadon: "Celadon"
        case .nocturne: "Nocturne"
        }
    }

    public var tier: AppThemeTier {
        switch self {
        case .mineral, .vermilion, .prussian: .core
        case .sienna, .celadon, .nocturne: .studio
        }
    }

    public static var coreThemes: [AppColorTheme] { allCases.filter { $0.tier == .core } }
    public static var studioThemes: [AppColorTheme] { allCases.filter { $0.tier == .studio } }
}

/// Pure, platform-independent appearance state machine corresponding to `spec/Appearance.tla`.
/// Surface finish and color pigment are orthogonal preferences: choosing a pigment never
/// forces a Solid (`.standard`) surface back into Clear glass.
public struct AppearanceState: Equatable, Sendable {
    public var surfaceMode: AppSurfaceMode
    public var colorTheme: AppColorTheme
    public var hasCustomBackdrop: Bool

    public init(
        surfaceMode: AppSurfaceMode = .clearGlass,
        colorTheme: AppColorTheme = .mineral,
        hasCustomBackdrop: Bool = false
    ) {
        self.surfaceMode = surfaceMode
        self.colorTheme = colorTheme
        self.hasCustomBackdrop = hasCustomBackdrop
    }

    public static func restored(
        savedSurfaceRaw: String?,
        legacyAppearanceRaw: String?,
        savedThemeRaw: String?,
        hasCustomBackdrop: Bool = false
    ) -> AppearanceState {
        let surface: AppSurfaceMode
        if let raw = savedSurfaceRaw, let parsed = AppSurfaceMode(rawValue: raw) {
            surface = parsed
        } else if legacyAppearanceRaw == "standard" {
            surface = .standard
        } else {
            surface = .clearGlass
        }

        let theme: AppColorTheme
        if let raw = savedThemeRaw, let parsed = AppColorTheme(rawValue: raw) {
            theme = parsed
        } else {
            theme = .mineral
        }

        return AppearanceState(
            surfaceMode: surface,
            colorTheme: theme,
            hasCustomBackdrop: hasCustomBackdrop
        )
    }

    public mutating func selectSurface(_ mode: AppSurfaceMode) {
        surfaceMode = mode
    }

    public mutating func selectTheme(_ theme: AppColorTheme) {
        colorTheme = theme
    }

    public mutating func importCustomBackdrop() {
        hasCustomBackdrop = true
        surfaceMode = .customImage
    }

    public mutating func removeCustomBackdrop() {
        hasCustomBackdrop = false
        if surfaceMode == .customImage {
            surfaceMode = .clearGlass
        }
    }

    public func usesGlassPanels(reduceTransparency: Bool, increaseContrast: Bool) -> Bool {
        surfaceMode.usesGlassPanels && !reduceTransparency && !increaseContrast
    }

    public func requestsTransparentWindow(reduceTransparency: Bool, increaseContrast: Bool) -> Bool {
        guard !reduceTransparency, !increaseContrast else { return false }
        return surfaceMode == .clearGlass || (surfaceMode == .customImage && !hasCustomBackdrop)
    }

    public func appliesSolidPigment(increaseContrast: Bool) -> Bool {
        surfaceMode == .standard && !increaseContrast
    }
}
