#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum AppSurfaceMode: String, CaseIterable, Identifiable {
    case clearGlass
    case ambientGlass
    case customImage
    case standard

    var id: Self { self }

    var title: String {
        switch self {
        case .clearGlass: "Clear"
        case .ambientGlass: "Ambient"
        case .customImage: "Photo"
        case .standard: "Solid"
        }
    }

    var subtitle: String {
        switch self {
        case .clearGlass: "See-through architectural glass"
        case .ambientGlass: "Painterly atmospheric wash"
        case .customImage: "Your image beneath frosted glass"
        case .standard: "Opaque native macOS finish"
        }
    }

    var usesGlassPanels: Bool {
        self != .standard
    }
}

enum AppThemeTier: String, CaseIterable, Identifiable {
    case core = "Essential"
    case studio = "Atelier"

    var id: Self { self }
}

enum AppColorTheme: String, CaseIterable, Identifiable {
    case mineral
    case vermilion
    case prussian
    case sienna
    case celadon
    case nocturne

    var id: Self { self }

    var title: String {
        switch self {
        case .mineral: "Mineral"
        case .vermilion: "Vermilion"
        case .prussian: "Prussian"
        case .sienna: "Sienna"
        case .celadon: "Celadon"
        case .nocturne: "Nocturne"
        }
    }

    var tier: AppThemeTier {
        switch self {
        case .mineral, .vermilion, .prussian: .core
        case .sienna, .celadon, .nocturne: .studio
        }
    }

    var swatchColors: [Color] {
        switch self {
        case .mineral:
            [Color(red: 0.78, green: 0.77, blue: 0.74), Color(red: 0.24, green: 0.24, blue: 0.25)]
        case .vermilion:
            [Color(red: 0.84, green: 0.24, blue: 0.18), Color(red: 0.13, green: 0.13, blue: 0.14)]
        case .prussian:
            [Color(red: 0.28, green: 0.49, blue: 0.86), Color(red: 0.09, green: 0.16, blue: 0.30)]
        case .sienna:
            [Color(red: 0.82, green: 0.46, blue: 0.28), Color(red: 0.18, green: 0.13, blue: 0.11)]
        case .celadon:
            [Color(red: 0.40, green: 0.68, blue: 0.62), Color(red: 0.14, green: 0.24, blue: 0.24)]
        case .nocturne:
            [Color(red: 0.30, green: 0.34, blue: 0.66), Color(red: 0.78, green: 0.48, blue: 0.60), Color(red: 0.86, green: 0.66, blue: 0.42)]
        }
    }

    static var coreThemes: [AppColorTheme] { allCases.filter { $0.tier == .core } }
    static var studioThemes: [AppColorTheme] { allCases.filter { $0.tier == .studio } }
}

@MainActor
final class AppearanceSettings: ObservableObject {
    nonisolated static let maximumBackdropBytes = 20 * 1024 * 1024

    private enum Keys {
        static let surfaceMode = "notifdexSurfaceMode"
        static let colorTheme = "notifdexColorTheme"
        static let legacyAppearance = "appAppearance"
        static let glassTintStrength = "notifdexGlassTintStrength"
        static let customBackdropBlur = "notifdexCustomBackdropBlur"
        static let customBackdropDim = "notifdexCustomBackdropDim"
        static let menuBarIconStyle = "notifdexMenuBarIconStyle"
    }

    private let defaults: UserDefaults
    let backdropURL: URL

    @Published var surfaceMode: AppSurfaceMode {
        didSet { defaults.set(surfaceMode.rawValue, forKey: Keys.surfaceMode) }
    }
    @Published var colorTheme: AppColorTheme {
        didSet { defaults.set(colorTheme.rawValue, forKey: Keys.colorTheme) }
    }
    @Published var menuBarIconStyle: MenuBarIconStyle {
        didSet { defaults.set(menuBarIconStyle.rawValue, forKey: Keys.menuBarIconStyle) }
    }
    @Published var glassTintStrength: Double {
        didSet { defaults.set(glassTintStrength, forKey: Keys.glassTintStrength) }
    }
    @Published var customBackdropBlur: Double {
        didSet { defaults.set(customBackdropBlur, forKey: Keys.customBackdropBlur) }
    }
    @Published var customBackdropDim: Double {
        didSet { defaults.set(customBackdropDim, forKey: Keys.customBackdropDim) }
    }
    @Published private(set) var customBackdropImage: NSImage?
    @Published var backdropError: String?
    @Published var showingBackdropImporter = false
    @Published var showingStudio = false

    init(directory: URL, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.backdropURL = directory.appendingPathComponent("custom-backdrop.img")

        if let raw = defaults.string(forKey: Keys.surfaceMode),
           let parsed = AppSurfaceMode(rawValue: raw) {
            self.surfaceMode = parsed
        } else if defaults.string(forKey: Keys.legacyAppearance) == "standard" {
            self.surfaceMode = .standard
        } else {
            self.surfaceMode = .clearGlass
        }

        if let raw = defaults.string(forKey: Keys.colorTheme),
           let parsed = AppColorTheme(rawValue: raw) {
            self.colorTheme = parsed
        } else {
            self.colorTheme = .mineral
        }

        if let raw = defaults.string(forKey: Keys.menuBarIconStyle),
           let parsed = MenuBarIconStyle(rawValue: raw) {
            self.menuBarIconStyle = parsed
        } else {
            self.menuBarIconStyle = .color
        }

        self.glassTintStrength = defaults.object(forKey: Keys.glassTintStrength) as? Double ?? 0.22
        self.customBackdropBlur = defaults.object(forKey: Keys.customBackdropBlur) as? Double ?? 12.0
        self.customBackdropDim = defaults.object(forKey: Keys.customBackdropDim) as? Double ?? 0.36

        loadSavedBackdrop()
    }

    var hasCustomBackdrop: Bool { customBackdropImage != nil }

    var activeConfiguration: AppearanceConfiguration {
        AppearanceConfiguration(
            surfaceMode: surfaceMode,
            colorTheme: colorTheme,
            glassTintStrength: glassTintStrength,
            customBackdropBlur: customBackdropBlur,
            customBackdropDim: customBackdropDim,
            customBackdropImage: customBackdropImage
        )
    }

    func selectSurface(_ mode: AppSurfaceMode) {
        backdropError = nil
        surfaceMode = mode
        if mode == .customImage && customBackdropImage == nil {
            showingBackdropImporter = true
        }
    }

    func selectTheme(_ theme: AppColorTheme) {
        backdropError = nil
        colorTheme = theme
        if surfaceMode == .standard {
            surfaceMode = .clearGlass
        }
    }

    func loadSavedBackdrop() {
        let url = backdropURL
        Task {
            let loaded: NSImage? = await Task.detached(priority: .utility) {
                guard let data = try? Data(contentsOf: url) else { return nil }
                return NSImage(data: data)
            }.value
            self.customBackdropImage = loaded
        }
    }

    func importBackdrop(_ result: Result<URL, Error>) {
        backdropError = nil
        let destination = backdropURL
        Task {
            do {
                let source = try result.get()
                let image: NSImage = try await Task.detached(priority: .userInitiated) {
                    try Self.copyAndValidateImage(from: source, to: destination)
                }.value
                self.customBackdropImage = image
                self.surfaceMode = .customImage
            } catch {
                self.backdropError = error.localizedDescription
            }
        }
    }

    func removeCustomBackdrop() {
        backdropError = nil
        let url = backdropURL
        customBackdropImage = nil
        if surfaceMode == .customImage {
            surfaceMode = .clearGlass
        }
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private nonisolated static func copyAndValidateImage(from source: URL, to destination: URL) throws -> NSImage {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw NSError(domain: "NotifdexAppearance", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Choose an image file (PNG, JPEG, HEIC, or WebP)."])
        }
        if let size = values.fileSize, size > maximumBackdropBytes {
            throw NSError(domain: "NotifdexAppearance", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Background images must be 20 MB or smaller."])
        }
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        guard data.count <= maximumBackdropBytes else {
            throw NSError(domain: "NotifdexAppearance", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Background images must be 20 MB or smaller."])
        }
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else {
            throw NSError(domain: "NotifdexAppearance", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Could not read that file as an image."])
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
        return image
    }
}

struct AppearanceConfiguration: Equatable {
    var surfaceMode: AppSurfaceMode = .clearGlass
    var colorTheme: AppColorTheme = .mineral
    var glassTintStrength: Double = 0.22
    var customBackdropBlur: Double = 12.0
    var customBackdropDim: Double = 0.36
    var customBackdropImage: NSImage?

    static func == (lhs: AppearanceConfiguration, rhs: AppearanceConfiguration) -> Bool {
        lhs.surfaceMode == rhs.surfaceMode &&
        lhs.colorTheme == rhs.colorTheme &&
        lhs.glassTintStrength == rhs.glassTintStrength &&
        lhs.customBackdropBlur == rhs.customBackdropBlur &&
        lhs.customBackdropDim == rhs.customBackdropDim &&
        (lhs.customBackdropImage === rhs.customBackdropImage)
    }

    var requestsTransparentWindow: Bool {
        surfaceMode == .clearGlass || (surfaceMode == .customImage && customBackdropImage == nil)
    }
}

private struct AppearanceConfigKey: EnvironmentKey {
    static let defaultValue = AppearanceConfiguration()
}

extension EnvironmentValues {
    var notifdexAppearanceConfig: AppearanceConfiguration {
        get { self[AppearanceConfigKey.self] }
        set { self[AppearanceConfigKey.self] = newValue }
    }
}

struct AmbientOrb {
    let color: Color
    let center: UnitPoint
    let radiusFactor: CGFloat
    let opacity: Double
}

struct ThemeTokens {
    let accent: Color
    let accentText: Color
    let windowTint: [Color]
    let ambientCanvas: [Color]
    let ambientOrbs: [AmbientOrb]
    let sidebarPlane: Color
    let inspectorPlane: Color
    let subtleFill: Color
    let hoverFill: Color
    let selectionFill: Color
    let hairline: Color
    let hairlineStrong: Color

    init(theme: AppColorTheme, dark: Bool) {
        hairline = dark ? Color.white.opacity(0.085) : Color.black.opacity(0.085)
        hairlineStrong = dark ? Color.white.opacity(0.18) : Color.black.opacity(0.18)
        hoverFill = dark ? Color.white.opacity(0.045) : Color.black.opacity(0.035)
        subtleFill = dark ? Color.white.opacity(0.05) : Color.black.opacity(0.035)

        switch theme {
        case .mineral:
            // Pure architectural smoked flint / gallery alabaster.
            accent = dark ? Color(red: 0.91, green: 0.89, blue: 0.86) : Color(red: 0.14, green: 0.14, blue: 0.15)
            accentText = dark ? Color(red: 0.08, green: 0.08, blue: 0.09) : Color.white
            windowTint = dark
                ? [Color(red: 0.11, green: 0.11, blue: 0.12), Color(red: 0.07, green: 0.07, blue: 0.08)]
                : [Color(red: 0.96, green: 0.95, blue: 0.94), Color(red: 0.92, green: 0.91, blue: 0.89)]
            ambientCanvas = dark
                ? [Color(red: 0.08, green: 0.08, blue: 0.085), Color(red: 0.11, green: 0.11, blue: 0.115)]
                : [Color(red: 0.95, green: 0.94, blue: 0.92), Color(red: 0.91, green: 0.90, blue: 0.88)]
            ambientOrbs = dark ? [
                AmbientOrb(color: Color(red: 0.72, green: 0.70, blue: 0.66), center: UnitPoint(x: 0.84, y: 0.14), radiusFactor: 0.56, opacity: 0.10),
                AmbientOrb(color: Color(red: 0.45, green: 0.47, blue: 0.52), center: UnitPoint(x: 0.14, y: 0.88), radiusFactor: 0.52, opacity: 0.10)
            ] : [
                AmbientOrb(color: Color(red: 0.98, green: 0.96, blue: 0.92), center: UnitPoint(x: 0.82, y: 0.12), radiusFactor: 0.58, opacity: 0.65),
                AmbientOrb(color: Color(red: 0.82, green: 0.81, blue: 0.79), center: UnitPoint(x: 0.18, y: 0.86), radiusFactor: 0.52, opacity: 0.36)
            ]
            sidebarPlane = dark ? Color.black.opacity(0.16) : Color.black.opacity(0.025)
            inspectorPlane = dark ? Color.white.opacity(0.03) : Color.white.opacity(0.32)
            selectionFill = dark ? Color.white.opacity(0.08) : Color.black.opacity(0.055)

        case .vermilion:
            // Editorial ink charcoal with a single surgical lacquer vermilion accent.
            accent = dark ? Color(red: 0.88, green: 0.27, blue: 0.21) : Color(red: 0.72, green: 0.18, blue: 0.14)
            accentText = Color.white
            windowTint = dark
                ? [Color(red: 0.09, green: 0.09, blue: 0.10), Color(red: 0.06, green: 0.06, blue: 0.07)]
                : [Color(red: 0.96, green: 0.95, blue: 0.94), Color(red: 0.93, green: 0.92, blue: 0.91)]
            ambientCanvas = dark
                ? [Color(red: 0.075, green: 0.075, blue: 0.082), Color(red: 0.10, green: 0.095, blue: 0.10)]
                : [Color(red: 0.96, green: 0.95, blue: 0.94), Color(red: 0.92, green: 0.91, blue: 0.90)]
            ambientOrbs = dark ? [
                AmbientOrb(color: Color(red: 0.78, green: 0.20, blue: 0.16), center: UnitPoint(x: 0.88, y: 0.12), radiusFactor: 0.45, opacity: 0.14)
            ] : [
                AmbientOrb(color: Color(red: 0.90, green: 0.72, blue: 0.68), center: UnitPoint(x: 0.86, y: 0.12), radiusFactor: 0.46, opacity: 0.24)
            ]
            sidebarPlane = dark ? Color.black.opacity(0.20) : Color.black.opacity(0.03)
            inspectorPlane = dark ? Color.white.opacity(0.03) : Color.white.opacity(0.34)
            selectionFill = dark ? accent.opacity(0.14) : accent.opacity(0.09)

        case .prussian:
            // Deep gallery ultramarine & cool misty slate (cobalt glass study).
            accent = dark ? Color(red: 0.44, green: 0.68, blue: 0.96) : Color(red: 0.14, green: 0.31, blue: 0.66)
            accentText = Color.white
            windowTint = dark
                ? [Color(red: 0.07, green: 0.13, blue: 0.26), Color(red: 0.05, green: 0.08, blue: 0.16)]
                : [Color(red: 0.90, green: 0.93, blue: 0.97), Color(red: 0.85, green: 0.89, blue: 0.95)]
            ambientCanvas = dark
                ? [Color(red: 0.06, green: 0.09, blue: 0.17), Color(red: 0.08, green: 0.14, blue: 0.27)]
                : [Color(red: 0.89, green: 0.92, blue: 0.97), Color(red: 0.83, green: 0.88, blue: 0.95)]
            ambientOrbs = dark ? [
                AmbientOrb(color: Color(red: 0.18, green: 0.40, blue: 0.84), center: UnitPoint(x: 0.80, y: 0.16), radiusFactor: 0.60, opacity: 0.30),
                AmbientOrb(color: Color(red: 0.38, green: 0.56, blue: 0.78), center: UnitPoint(x: 0.14, y: 0.86), radiusFactor: 0.50, opacity: 0.16)
            ] : [
                AmbientOrb(color: Color(red: 0.42, green: 0.62, blue: 0.92), center: UnitPoint(x: 0.82, y: 0.16), radiusFactor: 0.56, opacity: 0.28),
                AmbientOrb(color: Color(red: 0.78, green: 0.84, blue: 0.94), center: UnitPoint(x: 0.18, y: 0.84), radiusFactor: 0.52, opacity: 0.40)
            ]
            sidebarPlane = dark ? Color(red: 0.04, green: 0.08, blue: 0.16).opacity(0.24) : Color(red: 0.14, green: 0.24, blue: 0.46).opacity(0.035)
            inspectorPlane = dark ? Color(red: 0.40, green: 0.62, blue: 0.96).opacity(0.045) : Color.white.opacity(0.36)
            selectionFill = dark ? accent.opacity(0.14) : accent.opacity(0.10)

        case .sienna:
            // Smoked espresso & warm terracotta clay (Aesop / Dusk study).
            accent = dark ? Color(red: 0.86, green: 0.52, blue: 0.32) : Color(red: 0.65, green: 0.29, blue: 0.14)
            accentText = Color.white
            windowTint = dark
                ? [Color(red: 0.14, green: 0.10, blue: 0.085), Color(red: 0.08, green: 0.07, blue: 0.07)]
                : [Color(red: 0.96, green: 0.93, blue: 0.89), Color(red: 0.93, green: 0.89, blue: 0.84)]
            ambientCanvas = dark
                ? [Color(red: 0.085, green: 0.075, blue: 0.072), Color(red: 0.14, green: 0.10, blue: 0.085)]
                : [Color(red: 0.96, green: 0.93, blue: 0.89), Color(red: 0.92, green: 0.88, blue: 0.83)]
            ambientOrbs = dark ? [
                AmbientOrb(color: Color(red: 0.82, green: 0.40, blue: 0.18), center: UnitPoint(x: 0.74, y: 0.14), radiusFactor: 0.54, opacity: 0.24),
                AmbientOrb(color: Color(red: 0.56, green: 0.28, blue: 0.18), center: UnitPoint(x: 0.20, y: 0.88), radiusFactor: 0.48, opacity: 0.16)
            ] : [
                AmbientOrb(color: Color(red: 0.90, green: 0.66, blue: 0.48), center: UnitPoint(x: 0.78, y: 0.16), radiusFactor: 0.54, opacity: 0.28),
                AmbientOrb(color: Color(red: 0.94, green: 0.84, blue: 0.74), center: UnitPoint(x: 0.18, y: 0.86), radiusFactor: 0.52, opacity: 0.36)
            ]
            sidebarPlane = dark ? Color.black.opacity(0.20) : Color(red: 0.32, green: 0.20, blue: 0.12).opacity(0.035)
            inspectorPlane = dark ? Color(red: 0.96, green: 0.76, blue: 0.60).opacity(0.035) : Color.white.opacity(0.36)
            selectionFill = dark ? accent.opacity(0.15) : accent.opacity(0.10)

        case .celadon:
            // Ceramic porcelain & muted Song-dynasty celadon mineral glaze.
            accent = dark ? Color(red: 0.42, green: 0.74, blue: 0.66) : Color(red: 0.16, green: 0.44, blue: 0.40)
            accentText = Color.white
            windowTint = dark
                ? [Color(red: 0.07, green: 0.13, blue: 0.13), Color(red: 0.06, green: 0.09, blue: 0.10)]
                : [Color(red: 0.93, green: 0.95, blue: 0.94), Color(red: 0.88, green: 0.92, blue: 0.91)]
            ambientCanvas = dark
                ? [Color(red: 0.065, green: 0.10, blue: 0.105), Color(red: 0.09, green: 0.14, blue: 0.145)]
                : [Color(red: 0.94, green: 0.96, blue: 0.95), Color(red: 0.88, green: 0.92, blue: 0.91)]
            ambientOrbs = dark ? [
                AmbientOrb(color: Color(red: 0.26, green: 0.62, blue: 0.56), center: UnitPoint(x: 0.82, y: 0.16), radiusFactor: 0.56, opacity: 0.22),
                AmbientOrb(color: Color(red: 0.34, green: 0.52, blue: 0.58), center: UnitPoint(x: 0.16, y: 0.86), radiusFactor: 0.50, opacity: 0.16)
            ] : [
                AmbientOrb(color: Color(red: 0.48, green: 0.76, blue: 0.70), center: UnitPoint(x: 0.84, y: 0.16), radiusFactor: 0.54, opacity: 0.24),
                AmbientOrb(color: Color(red: 0.78, green: 0.88, blue: 0.86), center: UnitPoint(x: 0.18, y: 0.84), radiusFactor: 0.52, opacity: 0.36)
            ]
            sidebarPlane = dark ? Color.black.opacity(0.18) : Color(red: 0.12, green: 0.28, blue: 0.26).opacity(0.03)
            inspectorPlane = dark ? Color(red: 0.62, green: 0.88, blue: 0.84).opacity(0.035) : Color.white.opacity(0.38)
            selectionFill = dark ? accent.opacity(0.14) : accent.opacity(0.10)

        case .nocturne:
            // Painterly indigo, dusty rose-quartz, and warm ochre.
            accent = dark ? Color(red: 0.86, green: 0.58, blue: 0.68) : Color(red: 0.48, green: 0.26, blue: 0.44)
            accentText = Color.white
            windowTint = dark
                ? [Color(red: 0.11, green: 0.09, blue: 0.18), Color(red: 0.13, green: 0.08, blue: 0.13)]
                : [Color(red: 0.94, green: 0.92, blue: 0.95), Color(red: 0.95, green: 0.91, blue: 0.91)]
            ambientCanvas = dark
                ? [Color(red: 0.075, green: 0.07, blue: 0.13), Color(red: 0.12, green: 0.085, blue: 0.13)]
                : [Color(red: 0.94, green: 0.92, blue: 0.96), Color(red: 0.96, green: 0.92, blue: 0.90)]
            ambientOrbs = dark ? [
                AmbientOrb(color: Color(red: 0.28, green: 0.34, blue: 0.72), center: UnitPoint(x: 0.16, y: 0.16), radiusFactor: 0.60, opacity: 0.28),
                AmbientOrb(color: Color(red: 0.80, green: 0.44, blue: 0.56), center: UnitPoint(x: 0.84, y: 0.26), radiusFactor: 0.56, opacity: 0.22),
                AmbientOrb(color: Color(red: 0.86, green: 0.62, blue: 0.36), center: UnitPoint(x: 0.62, y: 0.92), radiusFactor: 0.50, opacity: 0.16)
            ] : [
                AmbientOrb(color: Color(red: 0.58, green: 0.62, blue: 0.88), center: UnitPoint(x: 0.16, y: 0.14), radiusFactor: 0.56, opacity: 0.26),
                AmbientOrb(color: Color(red: 0.90, green: 0.68, blue: 0.74), center: UnitPoint(x: 0.86, y: 0.26), radiusFactor: 0.54, opacity: 0.26),
                AmbientOrb(color: Color(red: 0.94, green: 0.82, blue: 0.64), center: UnitPoint(x: 0.62, y: 0.90), radiusFactor: 0.50, opacity: 0.28)
            ]
            sidebarPlane = dark ? Color.black.opacity(0.18) : Color(red: 0.24, green: 0.18, blue: 0.30).opacity(0.03)
            inspectorPlane = dark ? Color.white.opacity(0.035) : Color.white.opacity(0.36)
            selectionFill = dark ? accent.opacity(0.15) : accent.opacity(0.10)
        }
    }
}

enum AppearanceSurface: Equatable {
    case window
    case sidebar
    case list
    case inboxList
    case detail
    case inspector
    case card
    case pill
}

extension View {
    func notifdexAlertSelection(_ selected: Bool) -> some View {
        modifier(AlertSelectionTint(selected: selected))
    }

    func notifdexSurface(_ surface: AppearanceSurface) -> some View {
        modifier(AppSurfaceModifier(surface: surface))
    }
}

struct VisualEffectBackdrop: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    var alpha: CGFloat = 1.0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.alphaValue = alpha
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.alphaValue = alpha
    }
}

private struct AppWindowBackdrop: View {
    let config: AppearanceConfiguration
    let tokens: ThemeTokens
    let dark: Bool

    var body: some View {
        ZStack {
            switch config.surfaceMode {
            case .clearGlass:
                clearGlassBackdrop
            case .ambientGlass:
                ambientBackdrop
            case .customImage:
                if let image = config.customBackdropImage {
                    customImageBackdrop(image)
                } else {
                    clearGlassBackdrop
                }
            case .standard:
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .ignoresSafeArea()
    }

    private var clearGlassBackdrop: some View {
        let strength = max(0.0, min(1.0, config.glassTintStrength))
        // 0% = whisper-clear optical glass; 100% = deeper smoked architectural glass.
        let blurAlpha = 0.14 + strength * 0.72
        let glazeOpacity = 0.05 + strength * 0.42
        return ZStack {
            VisualEffectBackdrop(
                material: dark ? .hudWindow : .popover,
                blendingMode: .behindWindow,
                alpha: blurAlpha
            )
            LinearGradient(
                colors: tokens.windowTint.map { $0.opacity(glazeOpacity) },
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // Single quiet top-edge optical sheen.
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.white.opacity(dark ? 0.08 : 0.36), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 1)
                Spacer()
            }
        }
    }

    private var ambientBackdrop: some View {
        GeometryReader { proxy in
            let size = max(proxy.size.width, proxy.size.height)
            ZStack {
                LinearGradient(
                    colors: tokens.ambientCanvas,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                ForEach(tokens.ambientOrbs.indices, id: \.self) { index in
                    let orb = tokens.ambientOrbs[index]
                    RadialGradient(
                        colors: [orb.color.opacity(orb.opacity), .clear],
                        center: orb.center,
                        startRadius: 8,
                        endRadius: size * orb.radiusFactor
                    )
                }
            }
        }
    }

    private func customImageBackdrop(_ image: NSImage) -> some View {
        GeometryReader { proxy in
            ZStack {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .blur(radius: config.customBackdropBlur, opaque: true)
                    .scaleEffect(config.customBackdropBlur > 0 ? 1.06 : 1.0)
                (dark ? Color.black : Color.white)
                    .opacity(config.customBackdropDim)
                LinearGradient(
                    colors: tokens.windowTint.map { $0.opacity(0.20) },
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .clipped()
        }
    }
}

private struct AppSurfaceModifier: ViewModifier {
    let surface: AppearanceSurface

    @Environment(\.notifdexAppearanceConfig) private var config
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var usesGlass: Bool {
        config.surfaceMode.usesGlassPanels && !reduceTransparency && contrast != .increased
    }

    private var hidesScrollBackground: Bool {
        usesGlass && (surface == .list || surface == .inboxList)
    }

    func body(content: Content) -> some View {
        let dark = colorScheme == .dark
        let tokens = ThemeTokens(theme: config.colorTheme, dark: dark)
        content
            .scrollContentBackground(hidesScrollBackground ? .hidden : .automatic)
            .background(alignment: .center) {
                if surface == .window {
                    if usesGlass {
                        AppWindowBackdrop(config: config, tokens: tokens, dark: dark)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    } else {
                        Color(nsColor: .windowBackgroundColor)
                            .ignoresSafeArea()
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                } else if usesGlass {
                    architecturalPlane(tokens: tokens, dark: dark)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                } else {
                    standardPlane(dark: dark)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }

    @ViewBuilder
    private func architecturalPlane(tokens: ThemeTokens, dark: Bool) -> some View {
        switch surface {
        case .window:
            EmptyView()
        case .sidebar:
            // Starts cleanly beneath the unified full-width titlebar, separated by a 0.5pt rule.
            Rectangle()
                .fill(tokens.sidebarPlane)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(tokens.hairline).frame(width: 0.5)
                }
        case .inboxList, .list:
            // Open canvas: sits directly on the glass without a nested card frame.
            Color.clear
        case .detail, .inspector:
            // Quiet tonal plane with a razor-thin leading architectural hairline.
            Rectangle()
                .fill(tokens.inspectorPlane)
                .overlay(alignment: .leading) {
                    Rectangle().fill(tokens.hairline).frame(width: 0.5)
                }
        case .card:
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tokens.subtleFill)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(tokens.hairline, lineWidth: 0.5)
                }
        case .pill:
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tokens.subtleFill)
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(tokens.hairline, lineWidth: 0.5)
                }
        }
    }

    @ViewBuilder
    private func standardPlane(dark: Bool) -> some View {
        let rule = dark ? Color.white.opacity(0.09) : Color.black.opacity(0.09)
        switch surface {
        case .window:
            EmptyView()
        case .sidebar:
            Color(nsColor: .controlBackgroundColor).opacity(0.6)
                .overlay(alignment: .trailing) { Rectangle().fill(rule).frame(width: 0.5) }
        case .inboxList, .list:
            Color.clear
        case .detail, .inspector:
            Color(nsColor: .controlBackgroundColor).opacity(0.35)
                .overlay(alignment: .leading) { Rectangle().fill(rule).frame(width: 0.5) }
        case .card:
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(rule, lineWidth: 0.5)
                }
        case .pill:
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(rule, lineWidth: 0.5)
                }
        }
    }
}

private struct AlertSelectionTint: ViewModifier {
    let selected: Bool

    @Environment(\.notifdexAppearanceConfig) private var config
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.background {
            if selected && config.surfaceMode.usesGlassPanels && !reduceTransparency && contrast != .increased {
                let tokens = ThemeTokens(theme: config.colorTheme, dark: colorScheme == .dark)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tokens.selectionFill)
                    .padding(.horizontal, -8)
                    .padding(.vertical, -2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

struct NotifdexGlassButtonStyle: ButtonStyle {
    enum Emphasis {
        case regular
        case prominent
        case subtle
    }

    let emphasis: Emphasis
    let cornerRadius: CGFloat

    @Environment(\.notifdexAppearanceConfig) private var config
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    init(emphasis: Emphasis = .regular, cornerRadius: CGFloat = 6) {
        self.emphasis = emphasis
        self.cornerRadius = cornerRadius
    }

    func makeBody(configuration: Configuration) -> some View {
        let dark = colorScheme == .dark
        let tokens = ThemeTokens(theme: config.colorTheme, dark: dark)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        let fillColor: Color = switch emphasis {
        case .prominent:
            tokens.accent.opacity(configuration.isPressed ? 0.78 : 0.94)
        case .regular:
            tokens.subtleFill.opacity(configuration.isPressed ? 1.8 : 1.0)
        case .subtle:
            configuration.isPressed ? tokens.subtleFill : Color.clear
        }

        let borderColor: Color = switch emphasis {
        case .prominent:
            Color.clear
        case .regular:
            tokens.hairline
        case .subtle:
            Color.clear
        }

        configuration.label
            .font(.system(size: 12, weight: emphasis == .prominent ? .medium : .regular))
            .foregroundStyle(emphasis == .prominent ? tokens.accentText : Color.primary)
            .padding(.horizontal, emphasis == .subtle ? 6 : 11)
            .padding(.vertical, emphasis == .subtle ? 4 : 5)
            .background {
                shape.fill(fillColor)
                    .overlay { shape.strokeBorder(borderColor, lineWidth: 0.5) }
            }
            .opacity(isEnabled ? 1.0 : 0.42)
    }
}
#endif
