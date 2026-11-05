import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private(set) var statusItem: NSStatusItem?
  private var retainedMainWindow: NSWindow?
  private var customModeItem: NSMenuItem?
  private var systemDefaultItem: NSMenuItem?
  private var routingMode = "custom"
  private var quitPending = false
  private var quitTimeout: DispatchWorkItem?

  override func awakeFromNib() {
    super.awakeFromNib()
    configureMenuBarIfNeeded()
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    NSLog("[NetPilot] AppDelegate did finish launching")
    configureMenuBarIfNeeded()
  }

  private func configureMenuBarIfNeeded() {
    NSLog("[NetPilot] Configuring menu bar: hasItem=\(statusItem != nil)")
    // FlutterAppDelegate's outlet is weak. Keep the closed window (and its
    // Flutter engine) alive so opening NetPilot from the status item resumes it.
    retainedMainWindow = mainFlutterWindow
    NSLog("[NetPilot] Main window retained: \(retainedMainWindow != nil)")
    if statusItem == nil { installStatusItem() }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    DispatchQueue.main.async {
      if !(self.retainedMainWindow?.isVisible ?? false) {
        sender.setActivationPolicy(.accessory)
      }
    }
    return false
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    showMainWindow()
    return true
  }

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if quitPending { return .terminateLater }
    guard NetPilotPlugin.current?.emitEvent(["type": "quitRequested"]) == true else {
      return .terminateNow
    }
    quitPending = true
    let timeout = DispatchWorkItem { [weak self] in
      guard let self, self.quitPending else { return }
      NSLog("[NetPilot] Quit cleanup timed out; terminating")
      self.finishQuit()
    }
    quitTimeout = timeout
    // Hosts and route reconciliation may each wait up to eight seconds for XPC.
    DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
    return .terminateLater
  }

  func finishQuit() {
    guard quitPending else { return }
    quitPending = false
    quitTimeout?.cancel()
    quitTimeout = nil
    NSApp.reply(toApplicationShouldTerminate: true)
  }

  func setRoutingMode(_ mode: String) {
    guard mode == "custom" || mode == "systemDefault" else { return }
    routingMode = mode
    customModeItem?.state = mode == "custom" ? .on : .off
    systemDefaultItem?.state = mode == "systemDefault" ? .on : .off
  }

  func installStatusItem() {
    removeStatusItem()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.autosaveName = "com.netpilot.netpilotDesktop.statusItem"
    item.isVisible = true
    guard let button = item.button else {
      NSStatusBar.system.removeStatusItem(item)
      NSLog("[NetPilot] Failed to create menu bar button")
      return
    }
    let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
      .flatMap(NSImage.init(contentsOf:))
      ?? NSImage(systemSymbolName: "network", accessibilityDescription: "NetPilot")
    icon?.size = NSSize(width: 18, height: 18)
    button.image = icon
    button.toolTip = "NetPilot"
    button.target = self
    button.action = #selector(statusItemClicked(_:))
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    statusItem = item
    NSLog("[NetPilot] Menu bar item installed: visible=\(item.isVisible), icon=\(icon != nil)")
  }

  func removeStatusItem() {
    guard let item = statusItem else { return }
    NSStatusBar.system.removeStatusItem(item)
    statusItem = nil
  }

  @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
    if NSApp.currentEvent?.type == .rightMouseUp {
      let menu = NSMenu(title: "NetPilot")
      let open = NSMenuItem(title: "Open NetPilot", action: #selector(openFromStatusItem(_:)), keyEquivalent: "")
      open.target = self
      menu.addItem(open)
      menu.addItem(.separator())
      let custom = NSMenuItem(title: "Custom Routing", action: #selector(selectCustomMode(_:)), keyEquivalent: "")
      custom.target = self
      customModeItem = custom
      menu.addItem(custom)
      let systemDefault = NSMenuItem(title: "System Default", action: #selector(selectSystemDefaultMode(_:)), keyEquivalent: "")
      systemDefault.target = self
      systemDefaultItem = systemDefault
      menu.addItem(systemDefault)
      setRoutingMode(routingMode)
      menu.addItem(.separator())
      let quit = NSMenuItem(title: "Quit NetPilot", action: #selector(quitFromStatusItem(_:)), keyEquivalent: "")
      quit.target = self
      menu.addItem(quit)
      menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    } else {
      showMainWindow()
    }
  }

  @objc private func openFromStatusItem(_ sender: Any?) { showMainWindow() }

  @objc private func selectCustomMode(_ sender: Any?) {
    _ = NetPilotPlugin.current?.emitEvent(["type": "routingModeRequested", "mode": "custom"])
  }

  @objc private func selectSystemDefaultMode(_ sender: Any?) {
    _ = NetPilotPlugin.current?.emitEvent(["type": "routingModeRequested", "mode": "systemDefault"])
  }

  @objc private func quitFromStatusItem(_ sender: Any?) { NSApp.terminate(nil) }

  private func showMainWindow() {
    guard let window = retainedMainWindow ?? mainFlutterWindow else { return }
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
