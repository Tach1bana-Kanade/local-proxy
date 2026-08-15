import Foundation
import ProxyAppsCore

enum SystemPACManagerError: LocalizedError {
    case commandFailed(arguments: [String], output: String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let arguments, let output):
            let action = arguments.first ?? "networksetup"
            return "系统网络配置命令 \(action) 失败：\(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

final class SystemPACManager: SystemPACClient {
    typealias Runner = (_ arguments: [String]) throws -> (status: Int32, output: String)
    private let runner: Runner

    init(runner: @escaping Runner = SystemPACManager.runNetworkSetup) {
        self.runner = runner
    }

    func activeServiceNames() throws -> [String] {
        let output = try checked(["-listnetworkserviceorder"])
        return try SystemPACParser.activeServiceNames(from: output)
    }

    func currentState(for serviceName: String) throws -> NetworkServicePACState {
        try SystemPACParser.pacState(
            serviceName: serviceName,
            from: checked(["-getautoproxyurl", serviceName])
        )
    }

    func setState(_ state: NetworkServicePACState) throws {
        if let url = state.url {
            _ = try checked(["-setautoproxyurl", state.serviceName, url])
        } else if !state.enabled {
            _ = try? checked(["-setautoproxyurl", state.serviceName, ""])
        }
        _ = try checked(["-setautoproxystate", state.serviceName, state.enabled ? "on" : "off"])
    }

    func apply(
        pacURL: String,
        saveSnapshot: (NetworkServiceProxySnapshot) throws -> Void
    ) throws -> NetworkServiceProxySnapshot {
        try PACTransaction(client: self).apply(
            serviceNames: activeServiceNames(), managedPACURL: pacURL, beforeApply: saveSnapshot
        )
    }

    func restore(_ snapshot: NetworkServiceProxySnapshot, allowConflicts: Bool = false) throws {
        try PACTransaction(client: self).restore(snapshot, allowConflicts: allowConflicts)
    }

    private func checked(_ arguments: [String]) throws -> String {
        let result = try runner(arguments)
        guard result.status == 0 else {
            throw SystemPACManagerError.commandFailed(arguments: arguments, output: result.output)
        }
        return result.output
    }

    private static func runNetworkSetup(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
