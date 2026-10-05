import Foundation
import UIKit

public struct NameDropPayload: Codable, Equatable {
    public var version: Int
    public var peerId: Int64
    public var fullName: String
    public var username: String?
    public var backgroundEmoji: String?
    public var backgroundColorHex: Int32?
    public var avatarDataBase64: String?

    public init(version: Int = 1, peerId: Int64, fullName: String, username: String?, backgroundEmoji: String?, backgroundColorHex: Int32?, avatarDataBase64: String? = nil) {
        self.version = version
        self.peerId = peerId
        self.fullName = fullName
        self.username = username
        self.backgroundEmoji = backgroundEmoji
        self.backgroundColorHex = backgroundColorHex
        self.avatarDataBase64 = avatarDataBase64
    }
}

public struct NameDropSettings: Codable, Equatable {
    public var enabled: Bool
    public var backgroundEmoji: String?
    public var backgroundColorHex: Int32?

    public init(enabled: Bool = true, backgroundEmoji: String? = nil, backgroundColorHex: Int32? = nil) {
        self.enabled = enabled
        self.backgroundEmoji = backgroundEmoji
        self.backgroundColorHex = backgroundColorHex
    }
}

public final class NameDropSettingsStore {
    public static let shared = NameDropSettingsStore()

    private let enabledKey = "namedrop.enabled.v1"
    private let emojiKey = "namedrop.backgroundEmoji.v1"
    private let colorKey = "namedrop.backgroundColorHex.v1"

    public static let didChangeNotification = Notification.Name("NameDropSettingsDidChange")

    private init() {}

    public func get() -> NameDropSettings {
        let defaults = UserDefaults.standard
        let enabled: Bool
        if defaults.object(forKey: self.enabledKey) == nil {
            enabled = true
        } else {
            enabled = defaults.bool(forKey: self.enabledKey)
        }
        let emoji = defaults.string(forKey: self.emojiKey)
        let color: Int32?
        if defaults.object(forKey: self.colorKey) == nil {
            color = nil
        } else {
            color = Int32(defaults.integer(forKey: self.colorKey))
        }
        return NameDropSettings(enabled: enabled, backgroundEmoji: emoji?.isEmpty == true ? nil : emoji, backgroundColorHex: color)
    }

    public func setEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: self.enabledKey)
        self.notifyChanged()
    }

    public func setBackgroundEmoji(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            // Keep only the first grapheme cluster so the window stays clean.
            let first = String(trimmed.prefix(8))
            UserDefaults.standard.set(first, forKey: self.emojiKey)
        } else {
            UserDefaults.standard.removeObject(forKey: self.emojiKey)
        }
        self.notifyChanged()
    }

    public func setBackgroundColorHex(_ value: Int32?) {
        if let value {
            UserDefaults.standard.set(Int(value), forKey: self.colorKey)
        } else {
            UserDefaults.standard.removeObject(forKey: self.colorKey)
        }
        self.notifyChanged()
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: NameDropSettingsStore.didChangeNotification, object: nil)
    }
}

public extension UIColor {
    static func namedrop_color(hex: Int32) -> UIColor {
        let r = CGFloat((hex >> 16) & 0xff) / 255.0
        let g = CGFloat((hex >> 8) & 0xff) / 255.0
        let b = CGFloat(hex & 0xff) / 255.0
        return UIColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    var namedrop_hex: Int32 {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        self.getRed(&r, green: &g, blue: &b, alpha: &a)
        let ri = Int32((r * 255.0).rounded()) & 0xff
        let gi = Int32((g * 255.0).rounded()) & 0xff
        let bi = Int32((b * 255.0).rounded()) & 0xff
        return (ri << 16) | (gi << 8) | bi
    }
}
