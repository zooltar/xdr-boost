import Foundation

@main
enum BoostLevelSettingsTests {
    static func main() {
        testNormalizationUsesTenthsAndDisplayMaximum()
        testLevelsAreStoredIndependentlyByDisplay()
        testFallbackIsUsedForUnknownDisplay()
        print("BoostLevelSettingsTests passed")
    }

    private static func testNormalizationUsesTenthsAndDisplayMaximum() {
        assertEqual(BoostLevelSettings.normalized(1.04, maximum: 4.0), 1.0)
        assertEqual(BoostLevelSettings.normalized(1.05, maximum: 4.0), 1.1)
        assertEqual(BoostLevelSettings.normalized(9.0, maximum: 3.96), 3.9)
        assertEqual(BoostLevelSettings.normalized(0.5, maximum: 4.0), 1.0)
    }

    private static func testLevelsAreStoredIndependentlyByDisplay() {
        withIsolatedSettings { settings, defaults in
            assertEqual(settings.setLevel(1.7, for: "display-a", maximum: 4.0), 1.7)
            assertEqual(settings.setLevel(3.2, for: "display-b", maximum: 4.0), 3.2)

            let reloadedSettings = BoostLevelSettings(defaults: defaults)
            assertEqual(reloadedSettings.level(for: "display-a", maximum: 4.0), 1.7)
            assertEqual(reloadedSettings.level(for: "display-b", maximum: 3.0), 3.0)
        }
    }

    private static func testFallbackIsUsedForUnknownDisplay() {
        withIsolatedSettings { settings, _ in
            assertEqual(settings.level(for: "new-display", maximum: 1.85), 1.8)
        }
    }

    private static func withIsolatedSettings(
        _ body: (BoostLevelSettings, UserDefaults) -> Void
    ) {
        let suiteName = "BoostLevelSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create isolated defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = BoostLevelSettings(defaults: defaults)
        body(settings, defaults)
    }

    private static func assertEqual(
        _ actual: Double,
        _ expected: Double,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard abs(actual - expected) < 0.000_001 else {
            fatalError("Expected \(expected), got \(actual)", file: file, line: line)
        }
    }
}
