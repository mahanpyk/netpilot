import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    setContentSize(NSSize(width: 1180, height: 760))
    minSize = NSSize(width: 1180, height: 760)
    maxSize = NSSize(width: 1180, height: 760)
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    styleMask.insert(.fullSizeContentView)
    standardWindowButton(.closeButton)?.isHidden = true
    standardWindowButton(.miniaturizeButton)?.isHidden = true
    standardWindowButton(.zoomButton)?.isHidden = true

    RegisterGeneratedPlugins(registry: flutterViewController)
    NetPilotPlugin.register(with: flutterViewController.registrar(forPlugin: "NetPilotPlugin"))

    super.awakeFromNib()
  }
}
