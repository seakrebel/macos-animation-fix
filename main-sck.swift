//
//  AnimationFixSck — ScreenCaptureKit variant
//
//  Alternative build (./build.sh sck): the same menu-bar app, but the
//  capture session is a ScreenCaptureKit `SCStream` instead of a legacy
//  `CGDisplayStream`.  This is the officially supported API — it is the
//  fallback if a future macOS ever removes the obsoleted CGDisplayStream
//  symbols (the default build's only weak spot).
//
//  Differences vs. the default (main.swift):
//    - Routes through `replayd` (an extra system daemon for the session).
//    - Can change its frame rate on a running stream, which is what the
//      latch optimization below uses.
//
//  Latch optimization (verified by experiment): WindowServer engages the
//  smooth compositing mode once the capture pipeline delivers its first
//  real frame, and afterwards only needs the session to stay alive — frame
//  production can stop entirely (a live switch to an ∞ frame interval left
//  the UI smooth for many minutes).  So this build starts at 1 FPS and, on
//  the first delivered frame, switches the stream's minimumFrameInterval to
//  ~1e9 s via SCStream.updateConfiguration without stopping.  The session
//  stays alive but silent.
//

import AppKit
import ScreenCaptureKit
import CoreMedia

final class AppDelegate: NSObject,
    NSApplicationDelegate,
    SCStreamDelegate,
    SCStreamOutput
{

    private var statusItem: NSStatusItem!
    private var stream: SCStream?
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

    // Bumped on every new start/stop cycle; in-flight async captures from a
    // superseded cycle are ignored.
    private var startToken = 0

    private var retryCount = 0

    // True while we are deliberately stopping a stream, so an unexpected-stop
    // callback for it is not mistaken for a crash.
    private var stoppingDeliberately = false

    // Latch optimization: once the current session has delivered its first
    // real frame, the stream switches to an effectively-zero frame rate
    // (session stays alive, no more frames).  Reset on every (re)start.
    private var latchedQuiet = false

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
            "AnimationFixSck: environment changed: " +
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

        if let stream {
            // The system may have invalidated this stream (sleep, lock,
            // display change); discard it and build a fresh one.
            self.stream = nil
            enabled = false
            updateMenu()

            print("AnimationFixSck: discarding old stream before restart")
            stream.stopCapture { _ in }
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
            button.toolTip = "AnimationFixSck"
        }

        let menu = NSMenu()

        let titleItem = NSMenuItem(
            title: "AnimationFixSck",
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
                systemSymbolName: "wrench.fill",
                accessibilityDescription: enabled
                    ? "AnimationFixSck active"
                    : "AnimationFixSck paused"
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
        let token = startToken

        print("AnimationFixSck: starting capture...")

        SCShareableContent.getExcludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        ) { [weak self] content, error in

            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                guard token == self.startToken else {
                    return  // superseded by a newer start/stop cycle
                }

                if let error {
                    self.handleStartFailure(
                        "ERROR getting display",
                        error
                    )
                    return
                }

                guard let display = content?.displays.first else {
                    self.handleStartFailure(
                        "ERROR: no display found",
                        nil
                    )
                    return
                }

                print(
                    "AnimationFixSck: using display \(display.displayID)"
                )

                let filter = SCContentFilter(
                    display: display,
                    excludingWindows: []
                )

                let stream = SCStream(
                    filter: filter,
                    configuration: self.makeConfiguration(),
                    delegate: self
                )

                // Latch detector: count delivered frames (content ignored)
                // so we know the pipeline produced its first real frame.
                do {
                    try stream.addStreamOutput(
                        self,
                        type: .screen,
                        sampleHandlerQueue: DispatchQueue.main
                    )
                    print("AnimationFixSck: added frame detector")
                } catch {
                    print("AnimationFixSck: ERROR adding frame detector:")
                    print(error)
                }

                self.stream = stream
                self.latchedQuiet = false

                stream.startCapture { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self else {
                            return
                        }
                        guard token == self.startToken else {
                            return
                        }

                        if let error {
                            print(
                                "AnimationFixSck: ERROR starting capture:"
                            )
                            print(error)

                            if self.stream === stream {
                                self.stream = nil
                            }
                            self.enabled = false
                            self.updateMenu()
                            return
                        }

                        self.enabled = true
                        self.updateMenu()

                        print(
                            "AnimationFixSck: capture ACTIVE " +
                            "(1 FPS; going quiet after first frame)"
                        )
                    }
                }
            }
        }
    }

    private func handleStartFailure(_ message: String, _ error: Error?) {
        print("AnimationFixSck: \(message)")
        if let error {
            print(error)
        }

        // Failures right after wake/lock are often transient (the display
        // pipeline is still coming up).  Retry briefly, then give up and
        // wait for the next system event to try again.
        guard retryCount < 5 else {
            print(
                "AnimationFixSck: giving up after repeated failures"
            )
            enabled = false
            updateMenu()
            return
        }

        retryCount += 1
        let delay = Double(retryCount) * 2.0
        print(
            "AnimationFixSck: retrying in \(delay)s " +
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

        guard let stream else {
            enabled = false
            updateMenu()
            return
        }

        print("AnimationFixSck: stopping capture...")

        stream.stopCapture { [weak self] error in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                if let error {
                    print(
                        "AnimationFixSck: error stopping capture:"
                    )
                    print(error)
                }

                if self.stream === stream {
                    self.stream = nil
                }
                self.enabled = false
                self.updateMenu()

                print(
                    "AnimationFixSck: capture STOPPED"
                )
            }
        }
    }

    // MARK: - SCStreamOutput / latch optimization

    private func makeConfiguration(
        interval: CMTime = CMTime(value: 1, timescale: 1)
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()

        configuration.width = 64
        configuration.height = 36
        configuration.minimumFrameInterval = interval

        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.queueDepth = 1

        return configuration
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen else {
            return
        }
        // Only the current session's frames count (a stale frame from a
        // superseded stream must not trip the latch early).
        guard stream === self.stream else {
            return
        }
        guard !latchedQuiet else {
            return
        }

        latchedQuiet = true

        print(
            "AnimationFixSck: first frame delivered — switching to " +
            "quiet mode (∞) live, no stop"
        )

        // The smooth mode is latched by the first real frame; the session
        // only needs to stay alive now, so stop producing frames.
        stream.updateConfiguration(
            makeConfiguration(
                interval: CMTime(value: 1, timescale: 1_000_000_000)
            )
        ) { error in
            DispatchQueue.main.async {
                if let error {
                    print("AnimationFixSck: updateConfiguration error:")
                    print(error)
                    return
                }
                print(
                    "AnimationFixSck: quiet mode ACTIVE " +
                    "(session alive, no frames delivered)"
                )
            }
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("AnimationFixSck: stream stopped unexpectedly:")
        print(error)

        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            // Only react to the stream we currently care about, and only if
            // we did not stop it ourselves (toggle/quit/restart).
            guard self.stream === stream else {
                return
            }
            guard !self.stoppingDeliberately else {
                return
            }

            self.stream = nil
            self.enabled = false
            self.updateMenu()

            print("AnimationFixSck: scheduling restart")
            self.scheduleRestart()
        }
    }

    // MARK: - Quit

    @objc private func quit() {
        cancelPendingWork()
        stoppingDeliberately = true

        if let stream {
            stream.stopCapture { _ in
                DispatchQueue.main.async {
                    NSApplication.shared.terminate(nil)
                }
            }
        } else {
            NSApplication.shared.terminate(nil)
        }
    }
}

let application = NSApplication.shared

let delegate = AppDelegate()
application.delegate = delegate

application.setActivationPolicy(.accessory)

application.run()
