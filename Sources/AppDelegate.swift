import AppKit
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum State { case idle, holding(Date), handsFree, processing }

    private var statusItem: NSStatusItem!
    private let overlay = OverlayController()
    private let dictation = Dictation()
    private let whisper = WhisperEngine()
    private var state: State = .idle
    private var hotkeyDown = false
    private var ignoreNextRelease = false
    private var monitors: [Any] = []
    private var lastError: String?
    private var processingStarted: TimeInterval?

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(recording: false)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        dictation.onLevel = { [weak self] level in self?.overlay.model.push(level: level) }
        PersonalDictionary.ensureExists()
        installMonitors()
        whisper.start()

        Dictation.requestPermissions { [weak self] mic, speech in
            if !mic { self?.lastError = "Microphone access denied" }
            else if !speech { self?.lastError = "Speech Recognition access denied" }
        }
        // Accessibility lets us see the hotkey in other apps and paste with ⌘V.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        diag("launched, accessibility trusted=\(trusted ? "yes" : "no"), hotkey=\(Settings.hotkey.rawValue)")
        if !trusted { waitForAccessibility() }
    }

    /// Global key monitors only work once Accessibility is granted, so re-arm them the moment it is.
    private func waitForAccessibility() {
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted(), let self else { return }
            timer.invalidate()
            self.installMonitors()
            diag("accessibility granted, hotkey active")
            self.overlay.flash("Murmur is ready — hold \(Settings.hotkey.label)", seconds: 2.5)
        }
    }

    private func setIcon(recording: Bool) {
        let name = recording ? "waveform.circle.fill" : "waveform"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Murmur")
        img?.isTemplate = true
        statusItem.button?.image = img
    }

    // MARK: Hotkey

    private var eventTap: CFMachPort?
    private var eventsSeen = 0

    private func installMonitors() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false); eventTap = nil }
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()

        if installEventTap() {
            diag("event tap active (input monitoring=\(CGPreflightListenEventAccess() ? "yes" : "no"))")
        } else {
            diag("event tap failed; requesting Input Monitoring, falling back to NSEvent monitors")
            CGRequestListenEventAccess()
            if let m = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { [weak self] e in
                self?.handleKey(isFlags: e.type == .flagsChanged, keyCode: e.keyCode, flags: e.cgEvent?.flags ?? [])
            }) { monitors.append(m) }
        }
        // Events while Murmur itself is frontmost.
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { [weak self] e in
            self?.handleKey(isFlags: e.type == .flagsChanged, keyCode: e.keyCode, flags: e.cgEvent?.flags ?? [])
            return e
        }) { monitors.append(m) }
    }

    /// A listen-only Quartz event tap: sees modifier keys system-wide without blocking them.
    private func installEventTap() -> Bool {
        let mask = CGEventMask((1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue))
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                DispatchQueue.main.async { me.reenableTap() }
                return Unmanaged.passUnretained(event)
            }
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            let isFlags = type == .flagsChanged
            DispatchQueue.main.async { me.handleKey(isFlags: isFlags, keyCode: keyCode, flags: flags) }
            return Unmanaged.passUnretained(event)
        }, userInfo: refcon) else { return false }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func reenableTap() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func handleKey(isFlags: Bool, keyCode: UInt16, flags: CGEventFlags) {
        if eventsSeen < 5 { eventsSeen += 1; diag("key event seen: code=\(keyCode) flags=\(isFlags)") }
        if !isFlags {
            if keyCode == 53 { cancelRecording() } // Esc
            return
        }
        let hk = Settings.hotkey
        guard keyCode == hk.keyCode else { return }
        let down = flags.contains(hk.cgFlag)
        if down && !hotkeyDown { hotkeyDown = true; pressed() }
        else if !down && hotkeyDown { hotkeyDown = false; released() }
    }

    /// Hold to talk. A quick tap starts hands-free mode; tap again to finish. Esc cancels.
    private func pressed() {
        diag("hotkey pressed")
        switch state {
        case .idle:
            if startRecording() { state = .holding(Date()) }
        case .handsFree:
            ignoreNextRelease = true
            finishRecording()
        case .holding, .processing:
            break
        }
    }

    private func released() {
        if ignoreNextRelease { ignoreNextRelease = false; return }
        guard case .holding(let started) = state else { return }
        if Date().timeIntervalSince(started) < 0.3 {
            state = .handsFree
            overlay.show(.handsFree)
        } else {
            finishRecording()
        }
    }

    // MARK: Flow

    private func startRecording() -> Bool {
        do {
            try dictation.start(locale: Settings.language, vocabulary: PersonalDictionary.load().vocab,
                                requireApple: !useWhisper)
        } catch {
            lastError = error.localizedDescription
            diag("start failed: \(error.localizedDescription)")
            overlay.flash("⚠︎ \(error.localizedDescription)", seconds: 2.5)
            return false
        }
        lastError = nil
        if useWhisper { whisper.prepareForRecording() }
        Sound.play("Tink")
        setIcon(recording: true)
        overlay.show(.listening)
        return true
    }

    private func finishRecording() {
        state = .processing
        processingStarted = ProcessInfo.processInfo.systemUptime
        setIcon(recording: false)
        overlay.show(.transcribing)
        Sound.play("Pop")
        let whisperOn = useWhisper
        dictation.stop(waitForFinal: !whisperOn) { [weak self] appleText, samples in
            guard let self else { return }
            guard whisperOn else { self.process(appleText); return }
            self.whisper.transcribe(samples, prompt: self.whisperPrompt()) { [weak self] text in
                if text == nil { diag("whisper failed; using Apple transcript") }
                self?.process(text ?? appleText)
            }
        }
    }

    private var useWhisper: Bool { Settings.engine == "whisper" && whisper.isReady }

    /// Nudges Whisper toward simplified Chinese, mixed-language output and the user's own spellings.
    private func whisperPrompt() -> String {
        let vocab = PersonalDictionary.load().vocab
        var prompt = "以下是普通话的句子，可能夹杂English。"
        if !vocab.isEmpty { prompt += " " + vocab.joined(separator: ", ") + "." }
        return prompt
    }

    private func cancelRecording() {
        switch state {
        case .holding, .handsFree:
            dictation.cancel()
            state = .idle
            setIcon(recording: false)
            overlay.flash("Cancelled", seconds: 0.8)
        default:
            break
        }
    }

    private func process(_ raw: String) {
        if let started = processingStarted {
            diag(String(format: "timing: transcription %.2fs", ProcessInfo.processInfo.systemUptime - started))
        }
        let dict = PersonalDictionary.load()
        let basic = Cleanup.basic(raw, replacements: dict.replacements)
        guard !basic.isEmpty else {
            state = .idle
            processingStarted = nil
            overlay.flash("Didn't catch that")
            return
        }

        if Settings.aiCleanup, let key = Keychain.get() {
            overlay.show(.polishing)
            let input = Cleanup.applyReplacements(raw, dict.replacements)
            Cleanup.polish(input, apiKey: key, model: Settings.model, vocabulary: dict.vocab) { [weak self] polished in
                if polished == nil { self?.lastError = "Claude cleanup unavailable or took too long — used basic cleanup" }
                self?.deliver(polished ?? basic)
            }
        } else {
            deliver(basic)
        }
    }

    private func deliver(_ text: String) {
        if let started = processingStarted {
            diag(String(format: "timing: ready to paste %.2fs", ProcessInfo.processInfo.systemUptime - started))
        }
        processingStarted = nil
        state = .idle
        var h = Settings.history
        h.insert(text, at: 0)
        Settings.history = h
        if Paster.paste(text) {
            overlay.show(.hidden)
        } else {
            overlay.flash("Copied — press ⌘V (grant Accessibility to auto-paste)", seconds: 2.5)
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: "Hold \(Settings.hotkey.label) to dictate", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let sub = NSMenuItem(title: "Tap once for hands-free · Esc cancels", action: nil, keyEquivalent: "")
        sub.isEnabled = false
        menu.addItem(sub)

        if !AXIsProcessTrusted() {
            menu.addItem(item("⚠︎ Grant Accessibility access…", #selector(openAccessibility)))
        }
        if let lastError {
            let e = NSMenuItem(title: "⚠︎ \(lastError)", action: nil, keyEquivalent: "")
            e.isEnabled = false
            menu.addItem(e)
        }
        menu.addItem(.separator())

        // Recent
        let recent = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        let history = Settings.history
        if history.isEmpty {
            let none = NSMenuItem(title: "Nothing yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            recentMenu.addItem(none)
        }
        for (i, text) in history.enumerated() {
            let title = text.count > 60 ? String(text.prefix(60)) + "…" : text
            let it = item(title.replacingOccurrences(of: "\n", with: " "), #selector(copyHistory(_:)))
            it.tag = i
            it.toolTip = "Click to copy"
            recentMenu.addItem(it)
        }
        if !history.isEmpty {
            recentMenu.addItem(.separator())
            recentMenu.addItem(item("Clear History", #selector(clearHistory)))
        }
        recent.submenu = recentMenu
        menu.addItem(recent)
        menu.addItem(.separator())

        // Speech engine
        menu.addItem(submenu("Speech Engine", [("whisper", "Whisper — auto-detects language"),
                                               ("apple", "Apple — one language at a time")],
                             selected: Settings.engine, action: #selector(pickEngine(_:))))
        let ws = NSMenuItem(title: "   " + whisper.statusText, action: nil, keyEquivalent: "")
        ws.isEnabled = false
        menu.addItem(ws)
        // Language (Apple engine, and Whisper's backup)
        menu.addItem(submenu("Language (Apple engine)", Settings.languages.map { ($0.id, $0.name) },
                             selected: Settings.language, action: #selector(pickLanguage(_:))))
        // Hotkey
        menu.addItem(submenu("Hotkey", Hotkey.allCases.map { ($0.rawValue, $0.label) },
                             selected: Settings.hotkey.rawValue, action: #selector(pickHotkey(_:))))

        // AI cleanup
        let ai = NSMenuItem(title: "AI Cleanup", action: nil, keyEquivalent: "")
        let aiMenu = NSMenu()
        let hasKey = Keychain.get() != nil
        let toggle = item("Polish with Claude", #selector(toggleAI))
        toggle.state = Settings.aiCleanup && hasKey ? .on : .off
        toggle.isEnabled = hasKey
        aiMenu.addItem(toggle)
        aiMenu.addItem(.separator())
        for m in Settings.models {
            let it = item(m.name, #selector(pickModel(_:)))
            it.representedObject = m.id
            it.state = Settings.model == m.id ? .on : .off
            aiMenu.addItem(it)
        }
        aiMenu.addItem(.separator())
        aiMenu.addItem(item(hasKey ? "Change Claude API Key…" : "Set Claude API Key…", #selector(setAPIKey)))
        if hasKey { aiMenu.addItem(item("Remove API Key", #selector(removeAPIKey))) }
        ai.submenu = aiMenu
        menu.addItem(ai)

        menu.addItem(item("Edit Personal Dictionary…", #selector(openDictionary)))

        let sounds = item("Sound Effects", #selector(toggleSounds))
        sounds.state = Settings.sounds ? .on : .off
        menu.addItem(sounds)
        let login = item("Launch at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(item("Quit Murmur", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        return it
    }

    private func submenu(_ title: String, _ options: [(String, String)], selected: String, action: Selector) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu()
        for (id, name) in options {
            let it = item(name, action)
            it.representedObject = id
            it.state = id == selected ? .on : .off
            m.addItem(it)
        }
        parent.submenu = m
        return parent
    }

    // MARK: Menu actions

    @objc private func copyHistory(_ sender: NSMenuItem) {
        let h = Settings.history
        guard sender.tag < h.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(h[sender.tag], forType: .string)
    }
    @objc private func clearHistory() { Settings.history = [] }
    @objc private func pickLanguage(_ s: NSMenuItem) { if let id = s.representedObject as? String { Settings.language = id } }
    @objc private func pickHotkey(_ s: NSMenuItem) {
        if let id = s.representedObject as? String, let hk = Hotkey(rawValue: id) { Settings.hotkey = hk; hotkeyDown = false }
    }
    @objc private func pickModel(_ s: NSMenuItem) { if let id = s.representedObject as? String { Settings.model = id } }
    @objc private func toggleAI() { Settings.aiCleanup.toggle() }
    @objc private func toggleSounds() { Settings.sounds.toggle() }

    @objc private func setAPIKey() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Claude API Key"
        alert.informativeText = "Used to polish your dictation. Stored in your macOS Keychain. Get one at console.anthropic.com."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-ant-…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { Keychain.set(key); Settings.aiCleanup = true }
        }
    }
    @objc private func removeAPIKey() { Keychain.set(nil) }

    @objc private func openDictionary() {
        PersonalDictionary.ensureExists()
        NSWorkspace.shared.open(PersonalDictionary.url)
    }

    @objc private func openAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            lastError = "Launch at Login: \(error.localizedDescription)"
        }
    }

    @objc private func pickEngine(_ s: NSMenuItem) { if let id = s.representedObject as? String { Settings.engine = id } }

    func applicationWillTerminate(_ note: Notification) { whisper.stop() }

    @objc private func quit() { NSApp.terminate(nil) }
}
