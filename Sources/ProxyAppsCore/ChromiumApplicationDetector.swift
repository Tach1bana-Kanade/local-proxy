import Foundation

public enum ChromiumApplicationDetection: Equatable, Sendable {
    case chromium
    case notChromium
    case unreadable(String)

    public var isChromium: Bool { self == .chromium }
}

public enum ChromiumApplicationDetector {
    private static let knownBundleIdentifiers: Set<String> = [
        "com.brave.Browser",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Canary",
        "com.microsoft.edgemac.Dev",
        "com.operasoftware.Opera",
        "com.operasoftware.OperaDeveloper",
        "com.operasoftware.OperaNext",
        "com.vivaldi.Vivaldi",
        "company.thebrowser.Browser",
    ]

    /// 仅根据应用包内容判断，不依赖运行中的应用或持久化状态。
    public static func detect(bundleURL: URL, fileManager: FileManager = .default) -> ChromiumApplicationDetection {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: bundleURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .unreadable("应用包不存在或不是目录：\(bundleURL.path)")
        }

        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let frameworksURL = contentsURL.appendingPathComponent("Frameworks", isDirectory: true)
        let electronFrameworkURL = frameworksURL
            .appendingPathComponent("Electron Framework.framework", isDirectory: true)
        if fileManager.fileExists(atPath: electronFrameworkURL.path) {
            return .chromium
        }

        let infoURL = contentsURL.appendingPathComponent("Info.plist")
        let bundleIdentifier: String
        do {
            let data = try Data(contentsOf: infoURL)
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
            guard let dictionary = plist as? [String: Any] else {
                return .unreadable("Info.plist 不是有效的字典：\(infoURL.path)")
            }
            bundleIdentifier = dictionary["CFBundleIdentifier"] as? String ?? ""
        } catch {
            return .unreadable("无法读取 Info.plist（\(infoURL.path)）：\(error.localizedDescription)")
        }

        if knownBundleIdentifiers.contains(bundleIdentifier) {
            return .chromium
        }

        do {
            if fileManager.fileExists(atPath: frameworksURL.path) {
                let frameworkNames = try fileManager.contentsOfDirectory(atPath: frameworksURL.path)
                if frameworkNames.contains(where: { $0.localizedCaseInsensitiveContains("Chromium Framework") }) {
                    return .chromium
                }
            }
        } catch {
            return .unreadable("无法检查应用框架目录（\(frameworksURL.path)）：\(error.localizedDescription)")
        }

        let crashpadURL = contentsURL
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("chrome_crashpad_handler")
        if fileManager.fileExists(atPath: crashpadURL.path)
            || containsCrashpadHandler(in: frameworksURL, fileManager: fileManager) {
            return .chromium
        }

        return .notChromium
    }

    private static func containsCrashpadHandler(in directoryURL: URL, fileManager: FileManager) -> Bool {
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        for case let url as URL in enumerator where url.lastPathComponent == "chrome_crashpad_handler" {
            return true
        }
        return false
    }
}

public enum ProxyLaunchArguments {
    public static func websiteRules(pacURL: String) -> [String] { ["--proxy-pac-url=\(pacURL)"] }
    /// HTTP 代理地址与环境变量共用同一来源，避免两套端口配置发生偏差。
    public static func arguments(
        usingProxy: Bool,
        isChromium: Bool,
        environment: [String: String] = ProxyEnvironment.values
    ) -> [String] {
        guard usingProxy, isChromium,
              let httpProxy = environment["HTTP_PROXY"] ?? environment["http_proxy"],
              !httpProxy.isEmpty else {
            return []
        }
        return ["--proxy-server=\(httpProxy)"]
    }
}
