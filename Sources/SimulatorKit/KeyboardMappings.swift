import Foundation

public enum KeyboardMappings {
    public struct FunctionKey: Identifiable, Sendable {
        public let keyCode: UInt16
        public let title: String
        public var id: UInt16 { keyCode }
    }

    public enum Action: String, CaseIterable, Identifiable, Sendable {
        case none, home, back, recentApps, power, volumeUp, volumeDown, menu

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .none: return "None"
            case .home: return "Home"
            case .back: return "Back"
            case .recentApps: return "Recent Apps"
            case .power: return "Power"
            case .volumeUp: return "Volume Up"
            case .volumeDown: return "Volume Down"
            case .menu: return "Menu"
            }
        }
        public var androidKeyCode: UInt32? {
            switch self {
            case .none: return nil
            case .home: return 3
            case .back: return 4
            case .recentApps: return 187
            case .power: return 26
            case .volumeUp: return 24
            case .volumeDown: return 25
            case .menu: return 82
            }
        }
    }

    // macOS virtual key codes from Carbon/HIToolbox Events.h (kVK_F1–kVK_F8).
    public static let functionKeys: [FunctionKey] = [
        .init(keyCode: 0x7A, title: "F1"), .init(keyCode: 0x78, title: "F2"),
        .init(keyCode: 0x63, title: "F3"), .init(keyCode: 0x76, title: "F4"),
        .init(keyCode: 0x60, title: "F5"), .init(keyCode: 0x61, title: "F6"),
        .init(keyCode: 0x62, title: "F7"), .init(keyCode: 0x64, title: "F8")
    ]

    public static func action(for keyCode: UInt16, defaults: UserDefaults = .standard) -> Action {
        guard functionKeys.contains(where: { $0.keyCode == keyCode }),
              let value = defaults.string(forKey: preferenceKey(keyCode)),
              let action = Action(rawValue: value) else { return .none }
        return action
    }

    public static func setAction(_ action: Action, for keyCode: UInt16, defaults: UserDefaults = .standard) {
        guard functionKeys.contains(where: { $0.keyCode == keyCode }) else { return }
        if action == .none { defaults.removeObject(forKey: preferenceKey(keyCode)) }
        else { defaults.set(action.rawValue, forKey: preferenceKey(keyCode)) }
    }

    static func preferenceKey(_ keyCode: UInt16) -> String { "keyboardMapping.functionKey.\(keyCode)" }
}

/// Captures each physical key's first mapping until release, including unmapped
/// presses. Two physical keys may hold the same Android key without releasing it
/// prematurely when only one physical key is lifted.
public struct KeyboardPressState: Sendable {
    private struct Press: Sendable { let androidKeyCode: UInt32? }
    private var held: [UInt16: Press] = [:]

    public init() {}

    public mutating func keyDown(_ keyCode: UInt16, mapping: UInt32?) -> UInt32? {
        if let press = held[keyCode] { return press.androidKeyCode }
        held[keyCode] = Press(androidKeyCode: mapping)
        return mapping
    }

    public mutating func keyUp(_ keyCode: UInt16) -> UInt32? {
        guard let press = held.removeValue(forKey: keyCode), let code = press.androidKeyCode,
              !held.values.contains(where: { $0.androidKeyCode == code }) else { return nil }
        return code
    }

    public mutating func releaseAll() -> [UInt32] {
        let codes = Set(held.values.compactMap(\.androidKeyCode)).sorted()
        held.removeAll()
        return codes
    }
}
