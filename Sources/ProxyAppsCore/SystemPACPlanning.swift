import Foundation

public enum SystemPACParseError: Error, Equatable {
    case invalidServiceList
    case invalidPACState
}

public enum SystemPACParser {
    public static func activeServiceNames(from output: String) throws -> [String] {
        var result: [String] = []
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (index, line) in lines.enumerated() where line.hasPrefix("(") && line.contains(") ") {
            guard !line.hasPrefix("(*)"),
                  let close = line.firstIndex(of: ")") else { continue }
            let suffix = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            guard !suffix.isEmpty, index + 1 < lines.count else { continue }
            let hardwareLine = lines[index + 1]
            guard hardwareLine.contains("Device:"), !hardwareLine.contains("Device: )") else { continue }
            result.append(suffix)
        }
        guard !result.isEmpty else { throw SystemPACParseError.invalidServiceList }
        return result
    }

    public static func pacState(serviceName: String, from output: String) throws -> NetworkServicePACState {
        var enabled: Bool?
        var url: String?
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "enabled": enabled = parts[1].lowercased() == "yes"
            case "url": url = parts[1].isEmpty ? nil : parts[1]
            default: continue
            }
        }
        guard let enabled else { throw SystemPACParseError.invalidPACState }
        return NetworkServicePACState(serviceName: serviceName, enabled: enabled, url: url)
    }
}

public enum PACRestoreDecision: Equatable {
    case restore(NetworkServicePACState)
    case alreadyRestored
    case conflict(current: NetworkServicePACState, original: NetworkServicePACState)
}

public enum SystemPACPlanner {
    public static func restoreDecision(
        current: NetworkServicePACState,
        original: NetworkServicePACState,
        managedPACURL: String
    ) -> PACRestoreDecision {
        if current == original { return .alreadyRestored }
        if current.enabled && current.url == managedPACURL { return .restore(original) }
        return .conflict(current: current, original: original)
    }
}
