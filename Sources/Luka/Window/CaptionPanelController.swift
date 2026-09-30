import AppKit
import SwiftUI

final class CaptionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The caption strip: a borderless, non-activating glass panel that floats over everything,
/// including full-screen video, and never steals focus from the app you're watching.
@MainActor
final class CaptionPanelController: NSObject, NSWindowDelegate {
    static weak var current: CaptionPanelController?

    /// Transparent space above the caption where the hover toolbar appears.
    static let toolbarHeight: CGFloat = 38
    static let toolbarGap: CGFloat = 10
    static var chrome: CGFloat { toolbarHeight + toolbarGap }
    static let minWidth: CGFloat = 320

    private let model: AppModel
    private let panel: CaptionPanel
    private var dragStart: (mouse: NSPoint, frame: NSRect, lines: Int)?
    private var snapWork: DispatchWorkItem?
    private var unlockPanel: NSPanel?
    private var hoverTimer: Timer?

    init(model: AppModel) {
        self.model = model
        panel = CaptionPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                             backing: .buffered, defer: false)
        super.init()
        Self.current = self

        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.delegate = self
        panel.title = "Luka Captions"

        let host = NSHostingView(rootView: LocalizedRoot { CaptionRoot() }.environment(model))
        host.sizingOptions = []
        panel.contentView = host

        panel.setFrame(initialFrame(), display: false)
        applyLevel()
        observe()
    }

    var isVisible: Bool { panel.isVisible }

    var frame: NSRect {
        get { panel.frame }
        set { panel.setFrame(newValue, display: true) }
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    // MARK: Frame rules

    private var metrics: CaptionMetrics { CaptionMetrics(fontSize: model.captionFontSize) }

    private var targetHeight: CGFloat { Self.chrome + metrics.height(lines: model.captionLines) }

    private var screen: NSScreen { panel.screen ?? NSScreen.main ?? NSScreen.screens[0] }

    private func initialFrame() -> NSRect {
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let d = UserDefaults.standard
        let width = (d.object(forKey: "captionWidth") as? Double).map { CGFloat($0) } ?? min(visible.width * 0.6, 900)
        var frame = NSRect(x: visible.midX - width / 2, y: visible.minY + max(48, visible.height * 0.08),
                           width: width, height: targetHeight)
        if let x = d.object(forKey: "captionX") as? Double, let y = d.object(forKey: "captionY") as? Double {
            frame.origin = NSPoint(x: x, y: y)
        }
        return constrain(frame)
    }

    private func constrain(_ frame: NSRect) -> NSRect {
        let bounds = (NSScreen.screens.first { $0.frame.intersects(frame) } ?? screen).visibleFrame
        var f = frame
        f.size.width = min(max(f.width, Self.minWidth), bounds.width)
        f.origin.x = min(max(f.minX, bounds.minX), bounds.maxX - f.width)
        f.origin.y = min(max(f.minY, bounds.minY - Self.chrome), bounds.maxY - f.height)
        return f
    }

    /// Height follows the line count and text size; the bottom edge stays put so captions grow upward.
    private func applyHeight() {
        var frame = panel.frame
        guard abs(frame.height - targetHeight) > 0.5 else { return }
        frame.size.height = targetHeight
        frame = constrain(frame)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func applyLevel() {
        panel.level = model.captionPinned ? .floating : .normal
        panel.ignoresMouseEvents = model.locked
        if model.locked {
            if hoverTimer == nil {
                hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.trackLockedHover() }
                }
            }
        } else {
            hoverTimer?.invalidate()
            hoverTimer = nil
            setUnlockVisible(false)
        }
    }

    // MARK: Locked hover

    /// A locked caption ignores the mouse, so the way back is a separate little panel
    /// that appears above it while the pointer is over the caption.
    private func trackLockedHover() {
        let mouse = NSEvent.mouseLocation
        var caption = panel.frame
        caption.size.height -= Self.chrome
        let overPill = unlockPanel.map { $0.alphaValue > 0 && $0.frame.insetBy(dx: -6, dy: -6).contains(mouse) } ?? false
        setUnlockVisible(panel.isVisible && (caption.contains(mouse) || overPill))
    }

    private func setUnlockVisible(_ visible: Bool) {
        if visible && unlockPanel == nil { unlockPanel = makeUnlockPanel() }
        guard let pill = unlockPanel else { return }
        if visible {
            let size = pill.contentView?.fittingSize ?? NSSize(width: 160, height: 34)
            let origin = NSPoint(x: panel.frame.midX - size.width / 2,
                                 y: panel.frame.maxY - Self.chrome + Self.toolbarGap)
            pill.setFrame(NSRect(origin: origin, size: size), display: true)
            pill.level = NSWindow.Level(rawValue: panel.level.rawValue + 1)
            if !pill.isVisible { pill.alphaValue = 0; pill.orderFrontRegardless() }
        }
        let target: CGFloat = visible ? 1 : 0
        guard pill.alphaValue != target else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            pill.animator().alphaValue = target
        } completionHandler: {
            MainActor.assumeIsolated { if !visible && pill.alphaValue == 0 { pill.orderOut(nil) } }
        }
    }

    private func makeUnlockPanel() -> NSPanel {
        let pill = CaptionPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        pill.isOpaque = false
        pill.backgroundColor = .clear
        pill.hasShadow = false
        pill.hidesOnDeactivate = false
        pill.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingView(rootView: LocalizedRoot { UnlockPill() }.environment(model))
        host.sizingOptions = [.intrinsicContentSize]
        pill.contentView = host
        return pill
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(Double(panel.frame.width), forKey: "captionWidth")
        d.set(Double(panel.frame.minX), forKey: "captionX")
        d.set(Double(panel.frame.minY), forKey: "captionY")
    }

    // MARK: Edge dragging

    func drag(_ edge: Edge) {
        let mouse = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (mouse, panel.frame, model.captionLines) }
        guard let start = dragStart else { return }
        let dx = mouse.x - start.mouse.x
        let dy = mouse.y - start.mouse.y
        var frame = start.frame
        switch edge {
        case .leading:
            let width = max(Self.minWidth, start.frame.width - dx)
            frame.origin.x = start.frame.maxX - width
            frame.size.width = width
        case .trailing:
            frame.size.width = max(Self.minWidth, start.frame.width + dx)
        case .top, .bottom:
            let steps = Int(((edge == .top ? dy : -dy) / metrics.lineHeight).rounded())
            let lines = (start.lines + steps).clamped(to: AppModel.captionLineRange)
            if lines != model.captionLines { model.captionLines = lines }
            frame.size.height = targetHeight
            if edge == .bottom { frame.origin.y = start.frame.maxY - frame.height }
        }
        panel.setFrame(constrain(frame), display: true)
    }

    func endDrag() {
        dragStart = nil
        save()
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        snapWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.snapToCenter() }
        snapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// Dropping the strip near the middle of the screen centers it exactly.
    private func snapToCenter() {
        guard NSEvent.pressedMouseButtons == 0, dragStart == nil else {
            windowDidMove(Notification(name: NSWindow.didMoveNotification))
            return
        }
        let bounds = screen.visibleFrame
        var frame = panel.frame
        if abs(frame.midX - bounds.midX) < 28, abs(frame.midX - bounds.midX) > 0.5 {
            frame.origin.x = bounds.midX - frame.width / 2
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                panel.animator().setFrame(frame, display: true)
            }
        }
        save()
    }

    // MARK: Observation

    private func observe() {
        withObservationTracking {
            _ = model.captionLines
            _ = model.captionFontSize
            _ = model.captionPinned
            _ = model.locked
            _ = model.captionsVisible
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.applyHeight()
                self.applyLevel()
                if self.model.captionsVisible != self.panel.isVisible {
                    self.model.captionsVisible ? self.show() : self.hide()
                }
                self.observe()
            }
        }
    }
}
