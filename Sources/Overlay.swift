import AppKit
import SwiftUI

enum OverlayMode: Equatable {
    case hidden, listening, handsFree, transcribing, polishing
    case message(String)
}

final class OverlayModel: ObservableObject {
    @Published var mode: OverlayMode = .hidden
    @Published var levels: [CGFloat] = Array(repeating: 0, count: 20)

    func push(level: CGFloat) {
        levels.removeFirst()
        levels.append(level)
    }
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        HStack(spacing: 10) {
            switch model.mode {
            case .listening, .handsFree:
                Circle().fill(Color.red).frame(width: 8, height: 8)
                HStack(spacing: 3) {
                    ForEach(0..<model.levels.count, id: \.self) { i in
                        Capsule().fill(Color.white)
                            .frame(width: 3, height: 4 + model.levels[i] * 22)
                    }
                }
                .frame(height: 26)
                .animation(.easeOut(duration: 0.08), value: model.levels)
                if model.mode == .handsFree {
                    Text("hands-free · tap to finish").font(.system(size: 11)).foregroundColor(.white.opacity(0.7))
                }
            case .transcribing, .polishing:
                ProgressView().controlSize(.small).tint(.white)
                Text(model.mode == .transcribing ? "Transcribing…" : "Polishing…")
                    .font(.system(size: 12, weight: .medium)).foregroundColor(.white)
            case .message(let text):
                Text(text).font(.system(size: 12, weight: .medium)).foregroundColor(.white)
            case .hidden:
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Capsule().fill(Color.black.opacity(0.85)))
        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Floating pill near the bottom of the screen that never steals focus.
final class OverlayController {
    let model = OverlayModel()
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 56),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let host = NSHostingView(rootView: OverlayView(model: model))
        host.frame = panel.contentView!.bounds
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    func show(_ mode: OverlayMode) {
        hideWork?.cancel()
        if mode == .listening { model.levels = Array(repeating: 0, count: model.levels.count) }
        model.mode = mode
        if mode == .hidden { panel.orderOut(nil); return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.minY + 36))
        }
        panel.orderFrontRegardless()
    }

    func flash(_ text: String, seconds: Double = 1.6) {
        show(.message(text))
        let work = DispatchWorkItem { [weak self] in self?.show(.hidden) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
