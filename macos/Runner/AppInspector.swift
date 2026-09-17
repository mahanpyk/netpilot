import AppKit
import Security

enum AppInspectorError: LocalizedError {
  case notApplication
  case missingBundleIdentifier
  case unsigned(String)

  var errorDescription: String? {
    switch self {
    case .notApplication:
      return "Select a .app bundle."
    case .missingBundleIdentifier:
      return "The selected app has no bundle identifier."
    case .unsigned(let path):
      return "macOS could not read a signing identifier and Team ID from \(path)."
    }
  }
}

struct CodeIdentity: Hashable {
  let signingIdentifier: String
  let teamIdentifier: String
}

final class AppInspector {
  func inspect(url: URL) throws -> [String: Any] {
    guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url) else {
      throw AppInspectorError.notApplication
    }
    guard let bundleIdentifier = bundle.bundleIdentifier, !bundleIdentifier.isEmpty else {
      throw AppInspectorError.missingBundleIdentifier
    }
    let identity = try codeIdentity(at: url)
    let helpers = try helperIdentities(in: url)
      .filter { $0.teamIdentifier == identity.teamIdentifier }
      .map(\.signingIdentifier)
      .filter { $0 != identity.signingIdentifier }
      .sorted()

    let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
      ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
      ?? url.deletingPathExtension().lastPathComponent
    var result: [String: Any] = [
      "displayName": displayName,
      "bundlePath": url.path,
      "bundleIdentifier": bundleIdentifier,
      "signingIdentifier": identity.signingIdentifier,
      "teamIdentifier": identity.teamIdentifier,
      "helperSigningIdentifiers": helpers,
    ]
    if let icon = iconBase64(for: url) {
      result["iconPngBase64"] = icon
    }
    return result
  }

  func codeIdentity(at url: URL) throws -> CodeIdentity {
    var staticCode: SecStaticCode?
    let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
    guard createStatus == errSecSuccess, let staticCode else {
      throw AppInspectorError.unsigned(url.path)
    }
    var information: CFDictionary?
    let infoStatus = SecCodeCopySigningInformation(
      staticCode,
      SecCSFlags(rawValue: kSecCSSigningInformation),
      &information
    )
    guard infoStatus == errSecSuccess,
          let dictionary = information as? [String: Any],
          let signingIdentifier = dictionary[kSecCodeInfoIdentifier as String] as? String,
          let teamIdentifier = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
          !signingIdentifier.isEmpty,
          !teamIdentifier.isEmpty else {
      throw AppInspectorError.unsigned(url.path)
    }
    return CodeIdentity(
      signingIdentifier: signingIdentifier,
      teamIdentifier: teamIdentifier
    )
  }

  private func helperIdentities(in appURL: URL) throws -> Set<CodeIdentity> {
    let roots = [
      appURL.appendingPathComponent("Contents/Library/LoginItems"),
      appURL.appendingPathComponent("Contents/Library/LaunchServices"),
      appURL.appendingPathComponent("Contents/Library/XPCServices"),
      appURL.appendingPathComponent("Contents/Helpers"),
    ]
    let manager = FileManager.default
    var identities = Set<CodeIdentity>()
    for root in roots where manager.fileExists(atPath: root.path) {
      guard let enumerator = manager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      ) else { continue }
      while let candidate = enumerator.nextObject() as? URL {
        let ext = candidate.pathExtension.lowercased()
        guard ext == "app" || ext == "xpc" || manager.isExecutableFile(atPath: candidate.path) else {
          continue
        }
        do {
          identities.insert(try codeIdentity(at: candidate))
        } catch {
          NSLog("[NetPilot App Routing] Ignoring unsigned helper %@: %@", candidate.path, error.localizedDescription)
        }
      }
    }
    return identities
  }

  private func iconBase64(for appURL: URL) -> String? {
    let image = NSWorkspace.shared.icon(forFile: appURL.path)
    image.size = NSSize(width: 128, height: 128)
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
      return nil
    }
    return png.base64EncodedString()
  }
}
