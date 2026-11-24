import XCTest
@testable import NotifdexCore

final class AppearancePreferencesTests: XCTestCase {
    func testSelectingThemeInSolidModePreservesSolidSurface() {
        var state = AppearanceState(surfaceMode: .standard, colorTheme: .mineral)

        for theme in AppColorTheme.allCases {
            state.selectTheme(theme)
            XCTAssertEqual(state.surfaceMode, .standard, "Selecting \(theme) must not snap Solid back to Clear")
            XCTAssertEqual(state.colorTheme, theme)
            XCTAssertFalse(state.usesGlassPanels(reduceTransparency: false, increaseContrast: false))
            XCTAssertFalse(state.requestsTransparentWindow(reduceTransparency: false, increaseContrast: false))
            XCTAssertTrue(state.appliesSolidPigment(increaseContrast: false))
            XCTAssertFalse(state.appliesSolidPigment(increaseContrast: true))
        }
    }

    func testSelectingThemePreservesEverySurfaceMode() {
        for mode in AppSurfaceMode.allCases {
            var state = AppearanceState(
                surfaceMode: mode,
                colorTheme: .mineral,
                hasCustomBackdrop: mode == .customImage
            )
            state.selectTheme(.prussian)
            XCTAssertEqual(state.surfaceMode, mode)
            XCTAssertEqual(state.colorTheme, .prussian)
            XCTAssertEqual(state.hasCustomBackdrop, mode == .customImage)
        }
    }

    func testSelectingSurfacePreservesSelectedTheme() {
        var state = AppearanceState(surfaceMode: .clearGlass, colorTheme: .vermilion)

        for mode in AppSurfaceMode.allCases {
            state.selectSurface(mode)
            XCTAssertEqual(state.surfaceMode, mode)
            XCTAssertEqual(state.colorTheme, .vermilion)
        }
    }

    func testCustomBackdropLifecyclePreservesThemeAndNonPhotoSurfaces() {
        var state = AppearanceState(surfaceMode: .standard, colorTheme: .celadon)

        state.importCustomBackdrop()
        XCTAssertEqual(state.surfaceMode, .customImage)
        XCTAssertEqual(state.colorTheme, .celadon)
        XCTAssertTrue(state.hasCustomBackdrop)
        XCTAssertFalse(state.requestsTransparentWindow(reduceTransparency: false, increaseContrast: false))

        // Switching to Solid while keeping a saved backdrop, then removing the backdrop, stays Solid.
        state.selectSurface(.standard)
        state.removeCustomBackdrop()
        XCTAssertEqual(state.surfaceMode, .standard)
        XCTAssertEqual(state.colorTheme, .celadon)
        XCTAssertFalse(state.hasCustomBackdrop)

        // Removing the backdrop while Photo mode is active falls back to Clear while preserving theme.
        state.importCustomBackdrop()
        state.removeCustomBackdrop()
        XCTAssertEqual(state.surfaceMode, .clearGlass)
        XCTAssertEqual(state.colorTheme, .celadon)
        XCTAssertFalse(state.hasCustomBackdrop)
    }

    func testAccessibilityOverridesForceOpaqueWithoutMutatingPreferences() {
        let state = AppearanceState(surfaceMode: .clearGlass, colorTheme: .nocturne)

        XCTAssertTrue(state.usesGlassPanels(reduceTransparency: false, increaseContrast: false))
        XCTAssertTrue(state.requestsTransparentWindow(reduceTransparency: false, increaseContrast: false))

        XCTAssertFalse(state.usesGlassPanels(reduceTransparency: true, increaseContrast: false))
        XCTAssertFalse(state.requestsTransparentWindow(reduceTransparency: true, increaseContrast: false))

        XCTAssertFalse(state.usesGlassPanels(reduceTransparency: false, increaseContrast: true))
        XCTAssertFalse(state.requestsTransparentWindow(reduceTransparency: false, increaseContrast: true))
    }

    func testRestoredMigratesLegacyStandardAppearanceAndDefaultsCleanly() {
        let legacySolid = AppearanceState.restored(
            savedSurfaceRaw: nil,
            legacyAppearanceRaw: "standard",
            savedThemeRaw: "sienna"
        )
        XCTAssertEqual(legacySolid.surfaceMode, .standard)
        XCTAssertEqual(legacySolid.colorTheme, .sienna)

        let fresh = AppearanceState.restored(
            savedSurfaceRaw: nil,
            legacyAppearanceRaw: nil,
            savedThemeRaw: nil
        )
        XCTAssertEqual(fresh.surfaceMode, .clearGlass)
        XCTAssertEqual(fresh.colorTheme, .mineral)
    }
}
