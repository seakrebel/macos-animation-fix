import AppKit
import ScreenCaptureKit
import CoreMedia

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var stream: SCStream?
    private var enabled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        startCapture()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )

        if let button = statusItem.button {
            button.title = "◉"
            button.toolTip = "CompositorFix"
        }

        let menu = NSMenu()

        let titleItem = NSMenuItem(
            title: "CompositorFix",
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
    }

    private func updateMenu() {
        guard let menu = statusItem.menu,
              let enabledItem = menu.item(withTag: 100)
        else {
            return
        }

        enabledItem.state = enabled ? .on : .off

        if let button = statusItem.button {
            button.title = enabled ? "●" : "○"
        }
    }

    @objc private func toggleCapture() {
        if enabled {
            stopCapture()
        } else {
            startCapture()
        }
    }

    private func startCapture() {
        guard !enabled else {
            return
        }

        print("CompositorFix: starting capture...")

        SCShareableContent.getExcludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        ) { [weak self] content, error in

            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                if let error {
                    print("CompositorFix: ERROR getting display:")
                    print(error)

                    self.enabled = false
                    self.updateMenu()
                    return
                }

                guard let display = content?.displays.first else {
                    print("CompositorFix: ERROR: no display found")

                    self.enabled = false
                    self.updateMenu()
                    return
                }

                print(
                    "CompositorFix: using display \(display.displayID)"
                )

                let filter = SCContentFilter(
                    display: display,
                    excludingWindows: []
                )

                let configuration = SCStreamConfiguration()

                configuration.width = 64
                configuration.height = 36
                configuration.minimumFrameInterval =
                    CMTime(value: 1, timescale: 1)

                configuration.showsCursor = false
                configuration.capturesAudio = false
                configuration.queueDepth = 1

                let stream = SCStream(
                    filter: filter,
                    configuration: configuration,
                    delegate: nil
                )

                self.stream = stream

                stream.startCapture { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self else {
                            return
                        }

                        if let error {
                            print(
                                "CompositorFix: ERROR starting capture:"
                            )
                            print(error)

                            self.stream = nil
                            self.enabled = false
                            self.updateMenu()
                            return
                        }

                        self.enabled = true
                        self.updateMenu()

                        print(
                            "CompositorFix: capture ACTIVE"
                        )
                    }
                }
            }
        }
    }

    private func stopCapture() {
        guard let stream else {
            enabled = false
            updateMenu()
            return
        }

        print("CompositorFix: stopping capture...")

        stream.stopCapture { [weak self] error in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                if let error {
                    print(
                        "CompositorFix: error stopping capture:"
                    )
                    print(error)
                }

                self.stream = nil
                self.enabled = false
                self.updateMenu()

                print(
                    "CompositorFix: capture STOPPED"
                )
            }
        }
    }

    @objc private func quit() {
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
