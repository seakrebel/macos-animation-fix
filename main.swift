//
//  AnimationFix — default build (CGDisplayStream, no replayd)
//
//  Keeps a minimal display capture session alive to restore smooth UI
//  animations, implemented with the legacy CoreGraphics `CGDisplayStream`
//  API instead of ScreenCaptureKit.
//
//  Why this is the default: the same effect as the SCK variant, but with no
//  `replayd` daemon in the loop — `CGDisplayStream` is driven directly by
//  the WindowServer display-capture pipeline and hands frames to this
//  process via IOSurface.  Frames are deliberately ignored.
//
//  Differences vs. the SCK variant (main-sck.swift, ./build.sh sck):
//    - No `replayd` involvement (no SCStream, no content discovery).
//    - The whole display is captured (no window exclusion) and downscaled to
//      64 × 36 at 1 FPS.
//    - `CGDisplayStream` is obsolete in the macOS 15+ SDK; build.sh targets
//      macOS 14 so the symbols remain callable (still present at runtime on
//      macOS 26/27 — verified).  If a future macOS removes them, fall back
//      to the SCK variant: ./build.sh sck.
//

import AppKit
import CoreGraphics
import CoreVideo
import IOSurface

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var displayStream: CGDisplayStream?
    private var enabled = false

    // Whether the user wants the capture session running.  The actual stream
    // (`enabled`) can be down while `wantsEnabled` stays true (e.g. while the
    // screen is locked), which is what lets us automatically recover later.
    private var wantsEnabled = true

    // Coalesces the burst of environment-change events.  Dock transitions,
    // wake-from-sleep and display reconfiguration all fire several
    // notifications in quick succession, so we debounce restarts.
    private var restartWorkItem: DispatchWorkItem?

    // Pending delayed start after discarding an old stream.
    private var startWorkItem: DispatchWorkItem?

    // Pending retry after a transient start failure (e.g. right after wake).
    private var retryWorkItem: DispatchWorkItem?

    // Bumped on every new start/stop cycle; in-flight async work from a
    // superseded cycle is ignored.
    private var startToken = 0

    private var retryCount = 0

    // True while we are deliberately stopping, so an unexpected `.stopped`
    // callback for the stream is not mistaken for a crash.
    private var stoppingDeliberately = false

    // Frames delivered to our (ignored) handler; used to detect a stream that
    // never actually starts (typically missing Screen Recording permission).
    private var framesSeen = 0
    private var watchdogWorkItem: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        observeSystemEvents()
        wantsEnabled = true
        startCapture()
    }

    // MARK: - System event observation

    private func observeSystemEvents() {
        let nc = NSWorkspace.shared.notificationCenter

        // System wake from sleep (including opening the lid).
        nc.addObserver(
            self,
            selector: #selector(environmentChanged(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        // Displays waking (display sleep without full system sleep).
        nc.addObserver(
            self,
            selector: #selector(environmentChanged(_:)),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )

        // User session becomes active again (unlock / fast user switching).
        nc.addObserver(
            self,
            selector: #selector(environmentChanged(_:)),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )

        // Display configuration changes: docking stations, external display
        // connect/disconnect, resolution changes.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(environmentChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func environmentChanged(_ notification: Notification) {
        print(
            "AnimationFix: environment changed: " +
            notification.name.rawValue
        )
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard wantsEnabled else {
            return
        }

        cancelPendingWork()

        let workItem = DispatchWorkItem { [weak self] in
            self?.restartCapture()
        }
        restartWorkItem = workItem

        // Give the display configuration time to settle after the event.
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 2.0,
            execute: workItem
        )
    }

    private func restartCapture() {
        restartWorkItem = nil
        retryCount = 0
        stoppingDeliberately = true

        if let displayStream {
            // The system may have invalidated this stream (sleep, lock,
            // display change); discard it and build a fresh one.
            self.displayStream = nil
            enabled = false
            updateMenu()

            print("AnimationFix: discarding old stream before restart")
            displayStream.stop()
        }

        // Let the old session tear down before creating a new one.
        let workItem = DispatchWorkItem { [weak self] in
            self?.startCapture()
        }
        startWorkItem = workItem

        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.5,
            execute: workItem
        )
    }

    // MARK: - Menu bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )

        if let button = statusItem.button {
            button.toolTip = "AnimationFix"
        }

        let menu = NSMenu()

        let titleItem = NSMenuItem(
            title: "AnimationFix",
            action: nil,
            keyEquivalent: ""
        )
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(NSMenuItem.separator())

        let enabledItem = NSMenuItem(
            title: "Enabled",
            action: #selector(toggleCapture),
            keyEquivalent: ""
        )
        enabledItem.target = self
        enabledItem.tag = 100
        menu.addItem(enabledItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        // Initial icon state (dimmed until the stream is live).
        updateMenu()
    }

    private func updateMenu() {
        guard let menu = statusItem.menu,
              let enabledItem = menu.item(withTag: 100)
        else {
            return
        }

        enabledItem.state = enabled ? .on : .off

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: enabled
                    ? "wrench.and.screwdriver.fill"
                    : "wrench.and.screwdriver",
                accessibilityDescription: enabled
                    ? "AnimationFix active"
                    : "AnimationFix paused"
            )
            button.image?.isTemplate = true
            button.alphaValue = enabled ? 1.0 : 0.5
        }
    }

    @objc private func toggleCapture() {
        wantsEnabled.toggle()

        if wantsEnabled {
            retryCount = 0
            cancelPendingWork()
            startCapture()
        } else {
            stopCapture()
        }
    }

    private func cancelPendingWork() {
        restartWorkItem?.cancel()
        restartWorkItem = nil
        startWorkItem?.cancel()
        startWorkItem = nil
        retryWorkItem?.cancel()
        retryWorkItem = nil
        watchdogWorkItem?.cancel()
        watchdogWorkItem = nil
        startToken += 1
    }

    // MARK: - Capture lifecycle

    private func startCapture() {
        guard wantsEnabled else {
            return
        }
        guard !enabled else {
            return
        }

        startWorkItem = nil
        stoppingDeliberately = false
        startToken += 1

        print("AnimationFix: starting capture...")

        let displayID = CGMainDisplayID()
        guard displayID != kCGNullDirectDisplay else {
            handleStartFailure("ERROR: no display found", nil)
            return
        }

        print("AnimationFix: using display \(displayID)")

        let pixelFormat = Int32(bitPattern: kCVPixelFormatType_32BGRA)

        let properties: [CFString: Any] = [
            // 1 FPS — minimum time between delivered frames, in seconds.
            CGDisplayStream.minimumFrameTime: 1.0,
            CGDisplayStream.showCursor: false,
            // Queue as few frames as possible; we ignore them anyway.
            CGDisplayStream.queueDepth: 1,
        ]

        let handler: CGDisplayStreamFrameAvailableHandler = { [weak self] status, _, _, _ in
            // Deliberately ignore the frame surface — the session itself is
            // all we need.  Only track liveness and unexpected stops.
            guard let self else {
                return
            }

            self.framesSeen += 1

            if status == .stopped {
                guard self.enabled else {
                    return
                }
                guard !self.stoppingDeliberately else {
                    return
                }

                print(
                    "AnimationFix: stream stopped unexpectedly " +
                    "(display asleep or disconnected); " +
                    "scheduling restart"
                )
                self.scheduleRestart()
            }
        }

        // Swift overlay initializer for the legacy C function
        // CGDisplayStreamCreateWithDispatchQueue().
        guard let stream = CGDisplayStream(
            dispatchQueueDisplay: displayID,
            outputWidth: 64,
            outputHeight: 36,
            pixelFormat: pixelFormat,
            properties: properties as CFDictionary,
            queue: DispatchQueue.main,
            handler: handler
        ) else {
            handleStartFailure(
                "ERROR: CGDisplayStreamCreate returned nil",
                nil
            )
            return
        }

        self.displayStream = stream

        let error = stream.start()
        guard error == .success else {
            print("AnimationFix: ERROR starting capture:")
            print(error.rawValue)

            if self.displayStream === stream {
                self.displayStream = nil
            }
            self.enabled = false
            self.updateMenu()
            return
        }

        self.enabled = true
        self.updateMenu()

        print(
            "AnimationFix: capture ACTIVE " +
            "(CGDisplayStream, no replayd)"
        )

        // If the stream is live, the handler fires (frame or idle status)
        // roughly every second even on a static screen.  No callbacks at all
        // usually means Screen Recording permission is missing.
        framesSeen = 0
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            guard self.enabled else {
                return
            }
            if self.framesSeen == 0 {
                print(
                    "AnimationFix: WARNING: no frames/idle callbacks " +
                    "received — stream may be blocked.  Grant Screen " +
                    "Recording in System Settings → Privacy & Security, " +
                    "then relaunch."
                )
            }
        }
        watchdogWorkItem = watchdog
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 5.0,
            execute: watchdog
        )
    }

    private func handleStartFailure(_ message: String, _ error: Error?) {
        print("AnimationFix: \(message)")
        if let error {
            print(error)
        }

        // Failures right after wake/lock are often transient (the display
        // pipeline is still coming up).  Retry briefly, then give up and
        // wait for the next system event to try again.
        guard retryCount < 5 else {
            print(
                "AnimationFix: giving up after repeated failures"
            )
            enabled = false
            updateMenu()
            return
        }

        retryCount += 1
        let delay = Double(retryCount) * 2.0
        print(
            "AnimationFix: retrying in \(delay)s " +
            "(attempt \(retryCount)/5)"
        )

        let workItem = DispatchWorkItem { [weak self] in
            self?.startCapture()
        }
        retryWorkItem = workItem

        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
    }

    private func stopCapture() {
        cancelPendingWork()
        stoppingDeliberately = true

        guard let displayStream else {
            enabled = false
            updateMenu()
            return
        }

        print("AnimationFix: stopping capture...")

        displayStream.stop()

        self.displayStream = nil
        enabled = false
        updateMenu()

        print("AnimationFix: capture STOPPED")
    }

    // MARK: - Quit

    @objc private func quit() {
        cancelPendingWork()
        stoppingDeliberately = true

        if let displayStream {
            displayStream.stop()
            self.displayStream = nil
        }

        NSApplication.shared.terminate(nil)
    }
}

let application = NSApplication.shared

let delegate = AppDelegate()
application.delegate = delegate

application.setActivationPolicy(.accessory)

application.run()
