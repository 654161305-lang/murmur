import AppKit
import Security
import ApplicationServices

// MARK: - Settings

enum Hotkey: String, CaseIterable {
    case rightOption, rightCommand, fn

    var keyCode: UInt16 {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .fn: return 63
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .rightOption: return .option
        case .rightCommand: return .command
        case .fn: return .function
        }
    }

    var cgFlag: CGEventFlags {
        switch self {
        case .rightOption: return .maskAlternate
        case .rightCommand: return .maskCommand
        case .fn: return .maskSecondaryFn
        }
    }

    var label: String {
        switch self {
        case .rightOption: return "Right ⌥ Option"
        case .rightCommand: return "Right ⌘ Command"
        case .fn: return "fn / 🌐 Globe"
        }
    }
}

enum Settings {
    static let d = UserDefaults.standard

    static let languages: [(id: String, name: String)] = [
        ("en-US", "English (US)"), ("en-GB", "English (UK)"),
        ("zh-CN", "中文 (普通话)"), ("zh-TW", "中文 (台灣)"),
        ("fr-FR", "Français"), ("ja-JP", "日本語"),
    ]

    static let models: [(id: String, name: String)] = [
        ("claude-opus-5", "Claude Opus 5 (best quality)"),
        ("claude-haiku-4-5", "Claude Haiku 4.5 (fastest)"),
    ]

    static var language: String {
        get { d.string(forKey: "language") ?? "en-US" }
        set { d.set(newValue, forKey: "language") }
    }
    static var hotkey: Hotkey {
        get { Hotkey(rawValue: d.string(forKey: "hotkey") ?? "") ?? .rightCommand } // Right ⌥ clashes with Claude desktop's double-tap-Option Quick Entry
        set { d.set(newValue.rawValue, forKey: "hotkey") }
    }
    /// "whisper" (auto-detects language) or "apple" (one fixed language).
    static var engine: String {
        get { d.string(forKey: "engine") ?? "whisper" }
        set { d.set(newValue, forKey: "engine") }
    }
    static var aiCleanup: Bool {
        get { d.object(forKey: "aiCleanup") as? Bool ?? true }
        set { d.set(newValue, forKey: "aiCleanup") }
    }
    static var model: String {
        get { d.string(forKey: "model") ?? "claude-haiku-4-5" }
        set { d.set(newValue, forKey: "model") }
    }
    static var sounds: Bool {
        get { d.object(forKey: "sounds") as? Bool ?? true }
        set { d.set(newValue, forKey: "sounds") }
    }
    static var history: [String] {
        get { d.stringArray(forKey: "history") ?? [] }
        set { d.set(Array(newValue.prefix(25)), forKey: "history") }
    }
}

// MARK: - Keychain (Claude API key)

enum Keychain {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.local.murmur",
        kSecAttrAccount as String: "anthropic-api-key",
    ]

    static func get() -> String? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?) {
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var q = base
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}

// MARK: - Personal dictionary
// ~/Library/Application Support/Murmur/dictionary.txt
//   Acme Tea              -> a word the recognizer should know
//   acme tee => Acme Tea   -> always rewrite what it hears

enum PersonalDictionary {
    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dictionary.txt")
    }

    static func ensureExists() {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let sample = """
        # Murmur personal dictionary — one entry per line.
        # A plain word/phrase teaches the recognizer (and Claude) how to spell it.
        # "heard => written" always rewrites what the recognizer hears.
        Acme Tea
        macOS
        """
        try? sample.write(to: url, atomically: true, encoding: .utf8)
    }

    static func load() -> (vocab: [String], replacements: [(String, String)]) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return ([], []) }
        var vocab: [String] = []
        var reps: [(String, String)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.components(separatedBy: "=>")
            if parts.count == 2 {
                let from = parts[0].trimmingCharacters(in: .whitespaces)
                let to = parts[1].trimmingCharacters(in: .whitespaces)
                if !from.isEmpty { reps.append((from, to)); vocab.append(to) }
            } else {
                vocab.append(line)
            }
        }
        return (vocab, reps)
    }
}

// MARK: - Pasting into the frontmost app

enum Paster {
    /// Puts text on the clipboard and sends ⌘V. Restores the previous clipboard afterwards.
    /// Returns false when Accessibility isn't granted (text is left on the clipboard).
    static func paste(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for t in item.types { if let data = item.data(forType: t) { copy.setData(data, forType: t) } }
            return copy
        }
        pb.clearContents()
        pb.setString(text, forType: .string)

        guard AXIsProcessTrusted() else { return false }

        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true) // 9 = V
        let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard pb.string(forType: .string) == text else { return }
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
        return true
    }
}

enum Sound {
    static func play(_ name: String) {
        guard Settings.sounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}

// MARK: - Diagnostics (~/Library/Application Support/Murmur/status.log)

func diag(_ message: String) {
    let url = PersonalDictionary.url.deletingLastPathComponent().appendingPathComponent("status.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}
