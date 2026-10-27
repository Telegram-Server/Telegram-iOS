import Foundation
import UIKit

/// Where the main app keeps its data.
///
/// The app and its extensions share the App Group container. An IPA built without extensions
/// (`Make.py build --disableExtensions`) and re-signed without the App Group entitlement has no
/// container; it then keeps its data in its own Application Support directory instead of not
/// starting at all. With extensions in the bundle the App Group is required: the extensions could
/// not see a private directory.
enum AppDataContainer {
    /// The App Group container.
    case appGroup(URL)
    /// The app's own directory, used because the App Group is missing and no extension needs it.
    case standalone(URL)
    /// The App Group is missing and the bundle's extensions need it.
    case unavailable(details: String)

    var url: URL? {
        switch self {
        case let .appGroup(url), let .standalone(url):
            return url
        case .unavailable:
            return nil
        }
    }

    static func resolve(appGroupName: String) -> AppDataContainer {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupName) {
            return .appGroup(url)
        }
        let extensions = bundledExtensionNames()
        if extensions.isEmpty, let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let url = applicationSupport.appendingPathComponent("standalone-app-data", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                // Data the user can always re-download from the server stays out of iCloud/iTunes backups,
                // as the App Group container is.
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var mutableUrl = url
                try? mutableUrl.setResourceValues(values)
                return .standalone(url)
            } catch {
                return .unavailable(details: diagnostics(appGroupName: appGroupName, extensions: extensions, extra: "Creating \(url.path) failed: \(error)"))
            }
        }
        return .unavailable(details: diagnostics(appGroupName: appGroupName, extensions: extensions, extra: nil))
    }

    /// The names of the app extensions in the bundle (`PlugIns/*.appex`).
    static func bundledExtensionNames() -> [String] {
        guard let plugInsUrl = Bundle.main.builtInPlugInsURL, let contents = try? FileManager.default.contentsOfDirectory(atPath: plugInsUrl.path) else {
            return []
        }
        return contents.filter { $0.hasSuffix(".appex") }.sorted()
    }

    /// What a person re-signing the app needs to see: the App Group the app looks for and what the
    /// embedded provisioning profile actually grants.
    static func diagnostics(appGroupName: String, extensions: [String], extra: String?) -> String {
        var lines: [String] = []
        lines.append("Bundle id: \(Bundle.main.bundleIdentifier ?? "?")")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        lines.append("Version: \(version) (\(build))")
        lines.append("iOS: \(UIDevice.current.systemVersion)")
        lines.append("Required App Group: \(appGroupName)")
        lines.append("Extensions: \(extensions.isEmpty ? "none" : extensions.joined(separator: ", "))")
        if let profile = embeddedProvisioningProfile() {
            lines.append("Profile: \(profile["Name"] as? String ?? "?")")
            lines.append("Profile team: \((profile["TeamIdentifier"] as? [String])?.joined(separator: ", ") ?? "?")")
            if let expiration = profile["ExpirationDate"] as? Date {
                lines.append("Profile expires: \(expiration)")
            }
            let entitlements = profile["Entitlements"] as? [String: Any] ?? [:]
            lines.append("Profile application-identifier: \(entitlements["application-identifier"] as? String ?? "?")")
            let groups = entitlements["com.apple.security.application-groups"] as? [String] ?? []
            lines.append("Profile App Groups: \(groups.isEmpty ? "none" : groups.joined(separator: ", "))")
        } else {
            lines.append("Profile: no embedded.mobileprovision")
        }
        if let extra {
            lines.append(extra)
        }
        return lines.joined(separator: "\n")
    }

    /// The plist inside `embedded.mobileprovision`. The file is a CMS envelope around an XML plist;
    /// the plist is read out of it without verifying the signature, only to describe it.
    private static func embeddedProvisioningProfile() -> [String: Any]? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"), let data = try? Data(contentsOf: url) else {
            return nil
        }
        guard let start = data.range(of: Data("<?xml".utf8)), let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound ..< data.endIndex) else {
            return nil
        }
        let plistData = data.subdata(in: start.lowerBound ..< end.upperBound)
        return (try? PropertyListSerialization.propertyList(from: plistData, format: nil)) as? [String: Any]
    }
}

/// An alert for a launch that cannot continue, with the details to send to whoever builds or signs
/// the app. The window is not visible yet while the app is launching, so the alert is presented once
/// it is (`AppDelegate.attach(scene:connectionOptions:)`); presented earlier it would be dropped and
/// the app would show nothing but a white screen.
func makeLaunchFailureAlert(title: String, message: String, details: String?) -> UIAlertController {
    var fullMessage = message
    if let details {
        fullMessage += "\n\n" + details
    }
    let alert = UIAlertController(title: title, message: fullMessage, preferredStyle: .alert)
    if let details {
        alert.addAction(UIAlertAction(title: "Copy Details / 复制详情", style: .default, handler: { _ in
            UIPasteboard.general.string = title + "\n" + message + "\n\n" + details
        }))
    }
    alert.addAction(UIAlertAction(title: "OK", style: .cancel, handler: nil))
    return alert
}
