import Foundation

let delegate = HelperDelegate()
let listener = NSXPCListener(machServiceName: NetPilotXPCConstants.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
