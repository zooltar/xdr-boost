import Foundation

final class BoostLevelSettings {
    static let minimumLevel = 1.0
    static let step = 0.1
    static let defaultLevel = 2.0

    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "boostLevelsByDisplay"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    func level(
        for displayIdentifier: String,
        maximum: Double,
        fallback: Double = BoostLevelSettings.defaultLevel
    ) -> Double {
        let storedValue = storedLevels()[displayIdentifier] as? NSNumber
        return Self.normalized(storedValue?.doubleValue ?? fallback, maximum: maximum)
    }

    @discardableResult
    func setLevel(_ level: Double, for displayIdentifier: String, maximum: Double) -> Double {
        let normalizedLevel = Self.normalized(level, maximum: maximum)
        var levels = storedLevels()
        levels[displayIdentifier] = normalizedLevel
        defaults.set(levels, forKey: storageKey)
        return normalizedLevel
    }

    static func normalized(_ level: Double, maximum: Double) -> Double {
        let maximumLevel = maximumSelectableLevel(for: maximum)
        let roundedLevel = (level / step).rounded() * step
        return min(max(roundedLevel, minimumLevel), maximumLevel)
    }

    static func maximumSelectableLevel(for maximum: Double) -> Double {
        let steppedMaximum = floor((maximum + 0.000_001) / step) * step
        return max(minimumLevel, steppedMaximum)
    }

    private func storedLevels() -> [String: Any] {
        defaults.dictionary(forKey: storageKey) ?? [:]
    }
}
