import Foundation

public protocol SystemPACClient {
    func currentState(for serviceName: String) throws -> NetworkServicePACState
    func setState(_ state: NetworkServicePACState) throws
}

public enum PACTransactionError: LocalizedError {
    case noServices
    case applyFailed(service: String, underlying: String, rollbackFailures: [String])
    case restoreConflict([String])
    case restoreFailed(service: String, underlying: String, rollbackFailures: [String])

    public var errorDescription: String? {
        switch self {
        case .noServices:
            return "未找到已启用且具有网络接口的网络服务。"
        case .applyFailed(let service, let underlying, let failures):
            let rollback = failures.isEmpty ? "已回滚先前修改。" : "回滚失败：\(failures.joined(separator: "、"))。"
            return "为“\(service)”应用 PAC 失败：\(underlying)。\(rollback)"
        case .restoreConflict(let services):
            return "检测到 PAC 设置已被其他程序修改，未覆盖：\(services.joined(separator: "、"))。"
        case .restoreFailed(let service, let underlying, let failures):
            let rollback = failures.isEmpty ? "已恢复为本工具的 PAC 状态。" : "事务回滚失败：\(failures.joined(separator: "、"))。"
            return "恢复“\(service)”失败：\(underlying)。\(rollback)"
        }
    }
}

public struct PACTransaction {
    private let client: SystemPACClient

    public init(client: SystemPACClient) {
        self.client = client
    }

    public func apply(
        serviceNames: [String],
        managedPACURL: String,
        beforeApply: (NetworkServiceProxySnapshot) throws -> Void = { _ in }
    ) throws -> NetworkServiceProxySnapshot {
        guard !serviceNames.isEmpty else { throw PACTransactionError.noServices }
        let originals = try serviceNames.map(client.currentState)
        let snapshot = NetworkServiceProxySnapshot(managedPACURL: managedPACURL, services: originals)
        try beforeApply(snapshot)
        var attempted: [NetworkServicePACState] = []
        do {
            for original in originals {
                attempted.append(original)
                try client.setState(.init(serviceName: original.serviceName, enabled: true, url: managedPACURL))
            }
        } catch {
            let failures = rollback(attempted.reversed())
            let service = attempted.last?.serviceName ?? "未知服务"
            throw PACTransactionError.applyFailed(
                service: service, underlying: error.localizedDescription, rollbackFailures: failures
            )
        }
        return snapshot
    }

    public func restore(_ snapshot: NetworkServiceProxySnapshot, allowConflicts: Bool = false) throws {
        let current = try snapshot.services.map { try client.currentState(for: $0.serviceName) }
        if !allowConflicts {
            let conflicts = zip(current, snapshot.services).compactMap { current, original -> String? in
                if case .conflict = SystemPACPlanner.restoreDecision(
                    current: current, original: original, managedPACURL: snapshot.managedPACURL, ownedPACURLs: snapshot.ownedPACURLs ?? []
                ) {
                    let currentText = current.enabled ? (current.url ?? "已启用（无 URL）") : "关闭"
                    let originalText = original.enabled ? (original.url ?? "已启用（无 URL）") : "关闭"
                    return "\(original.serviceName)（当前：\(currentText)，原值：\(originalText)）"
                }
                return nil
            }
            guard conflicts.isEmpty else { throw PACTransactionError.restoreConflict(conflicts) }
        }

        var restoredIndices: [Int] = []
        do {
            for index in snapshot.services.indices {
                let decision = SystemPACPlanner.restoreDecision(
                    current: current[index],
                    original: snapshot.services[index],
                    managedPACURL: snapshot.managedPACURL, ownedPACURLs: snapshot.ownedPACURLs ?? []
                )
                if decision == .alreadyRestored { continue }
                restoredIndices.append(index)
                try client.setState(snapshot.services[index])
            }
        } catch {
            let failures = restoredIndices.reversed().compactMap { index -> String? in
                do { try client.setState(current[index]); return nil }
                catch { return snapshot.services[index].serviceName }
            }
            let service = restoredIndices.last.map { snapshot.services[$0].serviceName } ?? "未知服务"
            throw PACTransactionError.restoreFailed(
                service: service, underlying: error.localizedDescription, rollbackFailures: failures
            )
        }
    }

    /// Journal both exact URLs before changing any service; never replace the original snapshot.
    public func revise(_ snapshot: NetworkServiceProxySnapshot, newURL: String,
                       journal: (NetworkServiceProxySnapshot) throws -> Void) throws -> NetworkServiceProxySnapshot {
        let states = try snapshot.services.map { try client.currentState(for: $0.serviceName) }
        guard states.allSatisfy({ $0.enabled && $0.url == snapshot.managedPACURL }) else {
            throw PACTransactionError.restoreConflict(states.filter { !$0.enabled || $0.url != snapshot.managedPACURL }.map(\.serviceName))
        }
        var next = snapshot
        next.ownedPACURLs = Array(Set((snapshot.ownedPACURLs ?? []) + [snapshot.managedPACURL, newURL])).sorted()
        next.managedPACURL = newURL
        try journal(next)
        var attempted: [NetworkServicePACState] = []
        do {
            for state in states {
                attempted.append(state)
                try client.setState(.init(serviceName: state.serviceName, enabled: true, url: newURL))
            }
        } catch {
            let failures = rollback(attempted.reversed())
            if failures.isEmpty { try journal(snapshot) }
            throw PACTransactionError.applyFailed(service: attempted.last?.serviceName ?? "未知", underlying: error.localizedDescription, rollbackFailures: failures)
        }
        // Retain old ownership in journal for crash recovery; active revision still must match exactly on future edits.
        return next
    }

    private func rollback<S: Sequence>(_ states: S) -> [String] where S.Element == NetworkServicePACState {
        states.compactMap { state in
            do { try client.setState(state); return nil }
            catch { return state.serviceName }
        }
    }
}
