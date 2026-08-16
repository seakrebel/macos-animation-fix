//
//  AnimationFixSckLive — live frame-rate switch experiment
//
//  Purpose: settle whether the smoothing effect needs continuous frame
//  production ("ticking") or whether WindowServer latches into the smooth
//  mode on the first real frame and thereafter only needs the stream to
//  remain alive.
//
//  Hypothesis A (ticking): the effect requires periodic frame production;
//  if we stop delivering frames, UI stutters again.
//  Hypothesis B (latch): once the first frame has been delivered, the
//  smooth mode persists as long as the capture stream stays alive — even if
//  frames stop flowing.
//
//  Why not the CGDisplayStream path?  CGDisplayStream has no API to change
//  `minimumFrameTime` on a running stream (properties are read at creation),
//  so "change interval to ~∞ without stopping" is impossible there.
//  ScreenCaptureKit supports live reconfiguration via
//  `SCStream.updateConfiguration(_:completionHandler:)`, so this variant
//  uses SCK.
//
//  How to read the result:
//    - Start at 1 FPS (baseline, smooth).  Then use the menu to switch the
//      interval to ∞ (1e9 s — effectively no frames) WITHOUT stopping the
//      stream.
//    - UI stays smooth  → hypothesis B (latch; aliveness is enough).
//    - UI stutters again → hypothesis A (frames must keep flowing).
//
//  Instrumentation: a frame-counting `SCStreamOutput` (content ignored)
//  logs the actually-delivered frame rate, so the log proves the switch
//  really stopped frame delivery (otherwise a "stays smooth" result would
//  be ambiguous — it could just mean the config change didn't take).
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

    // ---- live rate-switch experiment state ----

    // The frame interval the stream currently uses.  Changed live through
    // the menu (updateConfiguration) and re-applied on stream restarts.
    private var currentInterval = CMTime(value: 1, timescale: 1)  // 1 s → 1 FPS

    // Frames delivered by SCStreamOutput in the current window (main queue
    // only, so no locking needed).
    private var frameCount = 0

    // Periodically logs the delivered frame rate.
    private var rateLogTimer: Timer?

    // MARK: - Application lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        observeSystemEvents()
        wantsEnabled = true
        startCapture()

        // Log the delivered frame rate every 10 s so the log shows the rate
        // actually changing after each menu switch.
        rateLogTimer = Timer.scheduledTimer(
            withTimeInterval: 10.0,
            repeats: true
        ) { [weak self] _ in
            self?.logFrameRate()
        }

        // Optional automated test hook: with ANIMFIX_AUTOSWITCH=<seconds>
        // set, switch to ∞ after that delay and back to 1 FPS after another
        // delay.  Lets the live-switch path be verified headlessly; normal
        // runs are unaffected (env var unset).
        if let s = ProcessInfo.processInfo.environment["ANIMFIX_AUTOSWITCH"],
           let delay = Double(s)
        {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                [weak self] in
                print("AnimationFixSckLive: [autoswitch] → ∞")
                self?.applyRate(tag: 203)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay * 2) {
                [weak self] in
                print("AnimationFixSckLive: [autoswitch] → 1 FPS")
                self?.applyRate(tag: 201)
            }
        }
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
            "AnimationFixSckLive: environment changed: " +
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

            print("AnimationFixSckLive: discarding old stream before restart")
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
            button.toolTip = "AnimationFixSckLive"
        }

        let menu = NSMenu()

        let titleItem = NSMenuItem(
            title: "AnimationFixSckLive",
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

        // Live frame-rate switches (applied without stopping the stream).
        let rateTitle = NSMenuItem(
            title: "Frame interval (live)",
            action: nil,
            keyEquivalent: ""
        )
        rateTitle.isEnabled = false
        menu.addItem(rateTitle)

        let rate1fps = NSMenuItem(
            title: "1 FPS (1 s)",
            action: #selector(setRate(_:)),
            keyEquivalent: ""
        )
        rate1fps.target = self
        rate1fps.tag = 201
        menu.addItem(rate1fps)

        let rate01fps = NSMenuItem(
            title: "0.1 FPS (10 s)",
            action: #selector(setRate(_:)),
            keyEquivalent: ""
        )
        rate01fps.target = self
        rate01fps.tag = 202
        menu.addItem(rate01fps)

        let rateInf = NSMenuItem(
            title: "∞ (1e9 s — no frames)",
            action: #selector(setRate(_:)),
            keyEquivalent: ""
        )
        rateInf.target = self
        rateInf.tag = 203
        menu.addItem(rateInf)

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

        // Check the rate item matching the current interval.
        let tag: Int
        if currentInterval.value == 1, currentInterval.timescale == 1 {
            tag = 201
        } else if currentInterval.value == 10, currentInterval.timescale == 1 {
            tag = 202
        } else {
            tag = 203
        }
        for t in [201, 202, 203] {
            menu.item(withTag: t)?.state = (t == tag) ? .on : .off
        }

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: enabled
                    ? "wrench.and.screwdriver.fill"
                    : "wrench.and.screwdriver",
                accessibilityDescription: enabled
                    ? "AnimationFixSckLive active"
                    : "AnimationFixSckLive paused"
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

    // MARK: - Live rate switching (the experiment)

    @objc private func setRate(_ sender: NSMenuItem) {
        applyRate(tag: sender.tag)
    }

    private func applyRate(tag: Int) {
        let interval: CMTime
        let label: String

        switch tag {
        case 201:
            interval = CMTime(value: 1, timescale: 1)          // 1 s
            label = "1 FPS"
        case 202:
            interval = CMTime(value: 10, timescale: 1)         // 10 s
            label = "0.1 FPS"
        case 203:
            interval = CMTime(value: 1, timescale: 1_000_000_000)  // 1e9 s
            label = "∞ (1e9 s)"
        default:
            return
        }

        currentInterval = interval
        updateMenu()

        guard let stream, enabled else {
            print(
                "AnimationFixSckLive: rate set to \(label) " +
                "(applies on next start)"
            )
            return
        }

        print(
            "AnimationFixSckLive: switching rate to \(label) " +
            "live (no stop)..."
        )

        stream.updateConfiguration(makeConfiguration()) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                if let error {
                    print(
                        "AnimationFixSckLive: updateConfiguration error:"
                    )
                    print(error)
                    return
                }
                print(
                    "AnimationFixSckLive: rate now \(label) — " +
                    "frames delivered since last log: \(self.frameCount)"
                )
                self.frameCount = 0
            }
        }
    }

    private func logFrameRate() {
        let n = frameCount
        frameCount = 0
        print(
            "AnimationFixSckLive: frames delivered in last 10 s: \(n) " +
            "(interval \(currentInterval.value)/\(currentInterval.timescale) s)"
        )
    }

    // MARK: - Capture lifecycle

    private func makeConfiguration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()

        configuration.width = 64
        configuration.height = 36
        configuration.minimumFrameInterval = currentInterval

        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.queueDepth = 1

        return configuration
    }

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

        print("AnimationFixSckLive: starting capture...")

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
                    "AnimationFixSckLive: using display \(display.displayID)"
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

                // Instrumentation only: count delivered frames so the log
                // shows the real rate after each live switch.  Content is
                // never inspected.
                do {
                    try stream.addStreamOutput(
                        self,
                        type: .screen,
                        sampleHandlerQueue: DispatchQueue.main
                    )
                    print(
                        "AnimationFixSckLive: added frame-counting output"
                    )
                } catch {
                    print(
                        "AnimationFixSckLive: ERROR adding output:"
                    )
                    print(error)
                }

                self.stream = stream
                self.frameCount = 0

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
                                "AnimationFixSckLive: ERROR starting capture:"
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
                            "AnimationFixSckLive: capture ACTIVE " +
                            "(interval \(self.currentInterval.value)/" +
                            "\(self.currentInterval.timescale) s)"
                        )
                    }
                }
            }
        }
    }

    private func handleStartFailure(_ message: String, _ error: Error?) {
        print("AnimationFixSckLive: \(message)")
        if let error {
            print(error)
        }

        // Failures right after wake/lock are often transient (the display
        // pipeline is still coming up).  Retry briefly, then give up and
        // wait for the next system event to try again.
        guard retryCount < 5 else {
            print(
                "AnimationFixSckLive: giving up after repeated failures"
            )
            enabled = false
            updateMenu()
            return
        }

        retryCount += 1
        let delay = Double(retryCount) * 2.0
        print(
            "AnimationFixSckLive: retrying in \(delay)s " +
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

        print("AnimationFixSckLive: stopping capture...")

        stream.stopCapture { [weak self] error in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                if let error {
                    print(
                        "AnimationFixSckLive: error stopping capture:"
                    )
                    print(error)
                }

                if self.stream === stream {
                    self.stream = nil
                }
                self.enabled = false
                self.updateMenu()

                print(
                    "AnimationFixSckLive: capture STOPPED"
                )
            }
        }
    }

    // MARK: - SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen else {
            return
        }
        // Count only.  The frame content is deliberately ignored.
        frameCount += 1
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("AnimationFixSckLive: stream stopped unexpectedly:")
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

            print("AnimationFixSckLive: scheduling restart")
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
