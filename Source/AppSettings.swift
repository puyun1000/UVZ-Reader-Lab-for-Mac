import AppKit

struct AppSettings {
    static let changed = Notification.Name("UVZReaderSettingsChanged")
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func bool(_ key: String, fallback: Bool) -> Bool { defaults.object(forKey: "settings." + key) == nil ? fallback : defaults.bool(forKey: "settings." + key) }
    func number(_ key: String, fallback: Int = 0) -> Int { defaults.object(forKey: "settings." + key) == nil ? fallback : defaults.integer(forKey: "settings." + key) }
    func set(_ value: Any, _ key: String) { defaults.set(value, forKey: "settings." + key); NotificationCenter.default.post(name: Self.changed, object: key) }
    var preserveFileDates: Bool { bool("preserveFileDates", fallback: true) }
    var backups: Bool { bool("backups", fallback: false) }
    var restoreSession: Bool { bool("restoreSession", fallback: true) }
    var rememberPosition: Bool { bool("rememberPosition", fallback: true) }
    var automaticOCR: Bool { bool("automaticOCR", fallback: true) }
    var metadataOCR: Bool { bool("metadataOCR", fallback: true) }
    var customTemplate: String { defaults.string(forKey: "settings.customTemplate") ?? "{书名}_{作者}_{出版社}_{出版日期}_{SS号}" }
    var readingState: ReadingState {
        var state = ReadingState(), mode = number("displayMode")
        mode = min(3, max(0, mode)); state.continuous = mode % 2 == 1; state.doublePages = mode >= 2
        state.coverAlone = bool("coverAlone", fallback: true); state.rightToLeft = bool("rightToLeft", fallback: false)
        state.wheelTurnsPages = bool("wheelTurnsPages", fallback: true)
        state.fit = min(3, max(0, number("fit"))); state.color = min(2, max(0, number("color")))
        return state
    }
}
