#if os(macOS)
import AppKit
import NotifdexCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct AppearanceStudioView: View {
    @ObservedObject var appearance: AppearanceSettings
    let dataDirectory: URL

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let dark = colorScheme == .dark
        let tokens = ThemeTokens(theme: appearance.colorTheme, dark: dark)

        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Appearance")
                    .font(.system(size: 17, weight: .regular, design: .serif))
                Text(appearance.surfaceMode.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if reduceTransparency || contrast == .increased {
                Text("System Reduce Transparency or Increase Contrast is enabled, so glass surfaces fall back to solid.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Editorial hairline tab bar for surface finish.
            HStack(spacing: 16) {
                ForEach(AppSurfaceMode.allCases) { mode in
                    surfaceTab(mode, selected: appearance.surfaceMode == mode, tokens: tokens)
                }
                Spacer(minLength: 0)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(tokens.hairline).frame(height: 0.5)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Essential")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                HStack(spacing: 12) {
                    ForEach(AppColorTheme.coreThemes) { theme in
                        pigmentSwatch(theme, selected: appearance.colorTheme == theme, tokens: tokens)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text("Atelier")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Studio")
                        .font(.system(size: 10, weight: .regular, design: .serif).italic())
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                HStack(spacing: 12) {
                    ForEach(AppColorTheme.studioThemes) { theme in
                        pigmentSwatch(theme, selected: appearance.colorTheme == theme, tokens: tokens)
                    }
                }
            }

            if appearance.surfaceMode == .clearGlass {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Glass density")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(appearance.glassTintStrength * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $appearance.glassTintStrength, in: 0.0...1.0)
                        .tint(tokens.accent)
                }
            }

            if appearance.surfaceMode == .customImage {
                customPhotoControls(tokens: tokens)
            }

            if let error = appearance.backdropError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Rectangle().fill(tokens.hairline).frame(height: 0.5)

            HStack(alignment: .firstTextBaseline) {
                Text("Menu bar icon")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 12) {
                    ForEach(MenuBarIconStyle.allCases) { style in
                        let active = appearance.menuBarIconStyle == style
                        Button {
                            appearance.menuBarIconStyle = style
                        } label: {
                            Text(style.title)
                                .font(.system(size: 11.5, weight: active ? .medium : .regular))
                                .foregroundStyle(active ? Color.primary : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Rectangle().fill(tokens.hairline).frame(height: 0.5)

            HStack {
                Button {
                    NSWorkspace.shared.open(dataDirectory)
                } label: {
                    Label("Show data folder", systemImage: "folder")
                }
                .buttonStyle(NotifdexGlassButtonStyle(emphasis: .subtle))
                Spacer()
                if appearance.surfaceMode != .customImage {
                    Button("Custom photo…") {
                        appearance.showingBackdropImporter = true
                    }
                    .buttonStyle(NotifdexGlassButtonStyle(emphasis: .subtle))
                }
            }
        }
        .padding(18)
        .frame(width: 310)
    }

    private func surfaceTab(_ mode: AppSurfaceMode, selected: Bool, tokens: ThemeTokens) -> some View {
        Button {
            appearance.selectSurface(mode)
        } label: {
            VStack(spacing: 6) {
                Text(mode.title)
                    .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                Rectangle()
                    .fill(selected ? tokens.accent : Color.clear)
                    .frame(height: 1.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func pigmentSwatch(_ theme: AppColorTheme, selected: Bool, tokens: ThemeTokens) -> some View {
        Button {
            appearance.selectTheme(theme)
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: theme.swatchColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 22, height: 22)
                        .overlay {
                            Circle()
                                .strokeBorder(Color.primary.opacity(selected ? 0.85 : 0.14), lineWidth: selected ? 1.5 : 0.5)
                                .padding(selected ? -3 : 0)
                        }
                }
                .frame(width: 30, height: 30)
                Text(theme.title)
                    .font(.system(size: 11, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func customPhotoControls(tokens: ThemeTokens) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if let image = appearance.customBackdropImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 40, height: 26)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(tokens.hairline, lineWidth: 0.5)
                        }
                }
                Button(appearance.hasCustomBackdrop ? "Change image…" : "Choose image…") {
                    appearance.showingBackdropImporter = true
                }
                .buttonStyle(NotifdexGlassButtonStyle())
                if appearance.hasCustomBackdrop {
                    Button("Remove") {
                        appearance.removeCustomBackdrop()
                    }
                    .buttonStyle(NotifdexGlassButtonStyle(emphasis: .subtle))
                }
                Spacer()
            }

            if appearance.hasCustomBackdrop {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Blur").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(appearance.customBackdropBlur)) pt")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Slider(value: $appearance.customBackdropBlur, in: 0...32)
                        .tint(tokens.accent)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Veil").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(appearance.customBackdropDim * 100))%")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Slider(value: $appearance.customBackdropDim, in: 0.05...0.75)
                        .tint(tokens.accent)
                }
            }
        }
    }
}
#endif
