import Foundation

enum AIMode: String, CaseIterable, Identifiable {
    case automatic, onDevice, gemini, basic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .onDevice: "On this device"
        case .gemini: "Gemini"
        case .basic: "Off (basic reading only)"
        }
    }

    static let storageKey = "aiMode"
}

/// Picks the AI engine according to the user's setting.
/// Automatic = Apple Intelligence if the phone supports it, else Gemini if a key is set, else none.
enum AIRouter {
    static var onDeviceAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return OnDeviceAI.isAvailable
        }
        #endif
        return false
    }

    static var mode: AIMode {
        AIMode(rawValue: UserDefaults.standard.string(forKey: AIMode.storageKey) ?? "") ?? .automatic
    }

    static func current(geminiKey: String) -> (any AIEngine)? {
        engine(for: mode, geminiKey: geminiKey)
    }

    static func engine(for mode: AIMode, geminiKey: String) -> (any AIEngine)? {
        func onDevice() -> (any AIEngine)? {
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *), OnDeviceAI.isAvailable {
                return OnDeviceAI()
            }
            #endif
            return nil
        }
        func gemini() -> (any AIEngine)? {
            geminiKey.isEmpty ? nil : GeminiAI(apiKey: geminiKey)
        }

        switch mode {
        case .automatic: return onDevice() ?? gemini()
        case .onDevice: return onDevice()
        case .gemini: return gemini()
        case .basic: return nil
        }
    }
}
