import AppKit
import ProxyAppsCore
import SwiftUI
import UniformTypeIdentifiers
import Network
import Darwin

enum WebsitePACStatus: Equatable { case disabled, enabled, failed(String), needsRestore }

@MainActor
final class ProxyAppsController: ObservableObject {
    @Published var applications: [ManagedApplication]
    @Published var configuration = RoutingConfiguration()
    @Published var activeMode: RoutingMode = .off
    @Published var websitePACStatus: WebsitePACStatus = .disabled
    @Published var quickcat = QuickcatStatus(socksAvailable: false, httpAvailable: false)
    @Published var systemProxyEnabled = false
    @Published var connections: [ProxyPortConnection] = []
    @Published var isBusy = false
    @Published var configurationBusy = false
    @Published private(set) var preparingToQuit = false
    @Published private(set) var pacByteCount = 0
    @Published var loadingRules = true
    @Published var updatingRules = false
    @Published var showingConsent = false
    @Published var hasRunDiagnostics = false
    @Published var showingError = false
    @Published var errorMessage = ""
    @Published var ruleError: String?
    @Published var notice = ""
    @Published var ruleCache: RuleSetCache?
    @Published var parsedRules: ParsedRuleSet?
    @Published var checkInput = ""
    @Published var checkDomain = ""
    @Published var checkDecision: RoutingDecision?
    @Published var checkResult: ProbeResult?
    @Published var checking = false
    private let manager: ProxyAppsManager
    private let systemPACManager: SystemPACManager
    private let pacContentStore = PACContentStore()
    private lazy var pacServer: PACServing = injectedServer ?? PACServer { [pacContentStore] revision in pacContentStore.content(revision: revision) }
    private let injectedServer: PACServing?
    private let pacValidation: ((String) async throws -> Void)?
    private var pacSettings: PACSettings
    private var configurationError: Error?
    private var currentPACURL: String?
    private var launchedPACApps: [UUID: (ManagedApplication, String)] = [:]
    private let updater: RuleSetUpdater
    private let probe = ConnectivityProbe()
    private var checkTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var checkGeneration = 0
    private var updateGeneration = 0
    private var matcher = DomainRuleMatcher(manual: [])
    private var schedule: UpdateSchedule
    private let pathMonitor = NWPathMonitor()

    init(manager: ProxyAppsManager = ProxyAppsManager(), systemPACManager: SystemPACManager = SystemPACManager(), pacServer: PACServing? = nil, pacValidation: ((String) async throws -> Void)? = nil, updater: RuleSetUpdater = RuleSetUpdater()) {
        self.updater = updater
        injectedServer = pacServer; self.pacValidation = pacValidation
        umask(0o077)
        self.manager = manager; self.systemPACManager = systemPACManager
        applications = manager.loadApplications(); pacSettings = manager.loadPACSettings()
        schedule = UpdateSchedule(lastSuccess: nil, now: Date())
        do { configuration = try manager.routingStore.load(); schedule = UpdateSchedule(lastSuccess: configuration.lastSuccessfulCheck, now: Date()) }
        catch { configurationError = error; notice = "配置损坏，原文件已保留；请修复 routing.json 后重启。\(error.localizedDescription)" }
        if manager.hasRestoreSnapshot || pacSettings.enabled { websitePACStatus = .needsRestore }
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.cancelCheck()
                await self.probe.invalidate()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.proxyapps.network-path"))
    }
    var websites: [ManagedWebsite] { configuration.manualRules }
    var enabledWebsiteCount: Int { websites.filter(\.enabled).count }
    var isWebsiteProxyEnabled: Bool { activeMode != .off && websitePACStatus == .enabled }
    var statusText: String { quickcat.httpAvailable ? "Quickcat 本机 HTTP 入口可连接" : "Quickcat 代理入口不可用" }
    var statusDetail: String { "端口连通不代表互联网畅通。运行中断开时保留代理规则，不自动改为直连。" }
    var websitePACStatusText: String {
        switch websitePACStatus {
        case .disabled: return "未启用"
        case .enabled: return activeMode == .smart ? "智能分流已配置到系统" : "仅手动规则已配置到系统"
        case .failed: return "配置未应用"
        case .needsRestore: return "需要恢复"
        }
    }
    var unlistedConnections: [ProxyPortConnection] {
        let names = Set(applications.map { $0.executableName.lowercased() })
        return connections.filter { $0.processName.lowercased() != "quickcat" && !names.contains($0.processName.lowercased()) }
    }
    func monitorStatus() async {
        guard monitorTask == nil else { return }
        monitorTask = Task { await runMonitor() }
    }
    private func runMonitor() async {
        let store = manager.ruleSetStore
        do {
            let loaded = try await Task.detached(priority: .utility) { () throws -> (RuleSetCache, String?, ParsedRuleSet) in
                let (cache, warning) = try store.load(); return (cache, warning, try cache.current.parse())
            }.value
            guard !Task.isCancelled, !preparingToQuit else { return }
            ruleCache = loaded.0; ruleError = loaded.1; parsedRules = loaded.2
            matcher = DomainRuleMatcher(manual: websites, automatic: loaded.2.rules)
        } catch { ruleError = "规则库不可用：\(error.localizedDescription)；可使用仅手动规则，或立即更新修复。" }
        loadingRules = false
        await refreshQuickcat()
        while !Task.isCancelled {
            if schedule.isDue(at: Date(), automatic: configuration.automaticUpdates), !updatingRules {
                Task { await self.updateRules() }
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            quickcat = await manager.inspectQuickcat()
        }
    }
    func requestSmart(_ enabled: Bool) {
        if enabled && configuration.needsConfirmation { showingConsent = true; return }
        Task { await setMode(enabled ? .smart : .off) }
    }
    func confirmSmart() { showingConsent = false; Task { await setMode(.smart, consent: true) } }
    func setWebsiteProxyEnabled(_ enabled: Bool) async { await setMode(enabled ? .manual : .off) }
    func setMode(_ mode: RoutingMode, consent: Bool = false) async {
        guard !configurationBusy, !preparingToQuit else { return }
        configurationBusy = true; defer { configurationBusy = false }
        do {
            if let configurationError { throw configurationError }
            guard websitePACStatus != .needsRestore else { throw RoutingError.invalid("请先恢复原网络设置") }
            if mode == .smart {
                guard parsedRules?.rules.isEmpty == false else { throw RoutingError.invalid("智能分流需要可用的非空规则库") }
                guard !configuration.needsConfirmation || consent else { showingConsent = true; return }
            }
            var candidate = configuration; candidate.preferredMode = mode
            if consent { candidate.confirmation = RoutingConfiguration.consentVersion }
            if mode == .off {
                // Persist the preference before restore; if restore fails revert preference and keep the journal.
                try manager.routingStore.save(candidate)
                do { try await disableWebsiteProxy() }
                catch { try manager.routingStore.save(configuration); throw error }
                configuration = candidate
            } else {
                quickcat = await manager.inspectQuickcat()
                guard quickcat.httpAvailable else { throw ProxyAppsError.quickcatHTTPUnavailable }
                try await commit(candidate, mode: mode)
            }
            notice = mode == .off ? "网站分流已关闭，原 PAC 已恢复。固定全部代理启动的应用仍继续运行。" : "配置已更新，必要时重新加载页面；按网站规则启动的应用可能需要重启。"
        } catch { handleConfigurationFailure(error) }
    }
    /// All active mutations enter through configurationBusy. Downloads never capture manual configuration.
    private func commit(_ candidate: RoutingConfiguration, mode: RoutingMode, rules: ParsedRuleSet? = nil,
                        cache: RuleSetCache? = nil) async throws {
        _ = try candidate.validated()
        let old = configuration, oldCache = ruleCache, oldURL = currentPACURL
        let automatic = (rules ?? parsedRules)?.rules ?? []
        let compiled = try await Task.detached(priority: .userInitiated) {
            // An off/manual update must not save a rule library that cannot later enable smart mode.
            if cache != nil && mode != .smart {
                _ = try PACValidation.compile(mode: .smart, manual: candidate.manualRules, automatic: automatic)
            }
            return (try PACValidation.compile(mode: mode, manual: candidate.manualRules, automatic: automatic),
                    DomainRuleMatcher(manual: candidate.manualRules, automatic: automatic))
        }.value
        guard !preparingToQuit else { throw CancellationError() }
        let revision = pacContentStore.stage(compiled.0)
        var nextURL: String?
        var applied = false
        do {
            if mode != .off {
                let port = try pacServer.start(preferredPort: pacSettings.port)
                pacSettings.port = port
                let url = "http://127.0.0.1:\(port)/proxy.pac?v=\(revision)"
                try await checkPAC(url)
                let system = systemPACManager, manager = manager
                try await Task.detached(priority: .userInitiated) {
                    if let snapshot = try manager.readRestoreSnapshot() {
                        _ = try PACTransaction(client: system).revise(snapshot, newURL: url, journal: manager.saveRestoreSnapshot)
                    } else {
                        _ = try system.apply(pacURL: url, saveSnapshot: manager.saveRestoreSnapshot)
                    }
                }.value
                applied = true; nextURL = url
            }
            if let cache { let store = manager.ruleSetStore; try await Task.detached(priority: .utility) { try store.save(cache) }.value }
            try manager.routingStore.save(candidate)
            if mode != .off { pacSettings.enabled = true; try manager.savePACSettings(pacSettings) }
        } catch {
            do {
                let system = systemPACManager, manager = manager, didApply = applied
                let removeInitialJournal = try await Task.detached(priority: .userInitiated) { () throws -> Bool in
                    if didApply, let snapshot = try manager.readRestoreSnapshot() {
                        if let oldURL { _ = try PACTransaction(client: system).revise(snapshot, newURL: oldURL, journal: manager.saveRestoreSnapshot) }
                        else { try system.restore(snapshot); return true }
                    } else if oldURL == nil, let snapshot = try manager.readRestoreSnapshot() {
                        try system.restore(snapshot); return true
                    }
                    return false
                }.value
                if cache != nil, let oldCache { let store = manager.ruleSetStore; try await Task.detached(priority: .utility) { try store.save(oldCache) }.value }
                try manager.routingStore.save(old)
                pacSettings.enabled = activeMode != .off
                try manager.savePACSettings(pacSettings)
                if removeInitialJournal { try manager.deleteRestoreSnapshot() }
                if oldURL == nil { pacServer.stop() }
            } catch {
                websitePACStatus = .needsRestore
                throw RoutingError.invalid("需要恢复：配置事务回滚失败，恢复记录已保留。\(error.localizedDescription)")
            }
            retainPACRevisions()
            throw error
        }
        pacContentStore.activate(revision)
        pacByteCount = compiled.0.utf8.count
        configuration = candidate; matcher = compiled.1
        if let cache { ruleCache = cache }; if let rules { parsedRules = rules }
        currentPACURL = nextURL; activeMode = mode; websitePACStatus = mode == .off ? .disabled : .enabled
        retainPACRevisions()
    }
    private func checkPAC(_ value: String) async throws {
        if let pacValidation { try await pacValidation(value); return }
        guard let url = URL(string: value) else { throw ProxyAppsError.pacUnavailable }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0, "ProxyAutoConfigEnable": 0]
        config.timeoutIntervalForRequest = 3; config.timeoutIntervalForResource = 4
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              PACGenerator.revision(String(data: data, encoding: .utf8) ?? "") == URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value else { throw ProxyAppsError.pacUnavailable }
    }
    private func disableWebsiteProxy(allowConflicts: Bool = false) async throws {
        do {
            if let snapshot = try manager.readRestoreSnapshot() {
                let system = systemPACManager
                try await Task.detached(priority: .userInitiated) { try system.restore(snapshot, allowConflicts: allowConflicts) }.value
            } else if pacSettings.enabled { throw RoutingError.invalid("恢复记录缺失，不能确认原 PAC；请核对系统设置后修复 pac-settings.json") }
            // Network is now restored. A later disk error must never keep the UI marked active.
            pacServer.stop(); currentPACURL = nil; activeMode = .off
            pacSettings.enabled = false; try manager.savePACSettings(pacSettings)
            try manager.deleteRestoreSnapshot()
            websitePACStatus = .disabled
        } catch { websitePACStatus = .needsRestore; throw error }
    }
    func restoreOriginalNetworkSettings(allowConflicts: Bool = false) async {
        guard !configurationBusy, !preparingToQuit else { return }
        configurationBusy = true; defer { configurationBusy = false }
        do { try await disableWebsiteProxy(allowConflicts: allowConflicts) }
        catch { websitePACStatus = .needsRestore; present(error) }
    }
    /// Called before macOS commits to quitting, so a failed restore can cancel termination.
    @discardableResult
    func shutdownForTermination() async -> Bool {
        guard !preparingToQuit else { return false }
        preparingToQuit = true
        updateGeneration += 1
        checkTask?.cancel()
        await updater.cancel()
        await probe.cancel()
        // Let an already-publishing transaction finish/rollback before restoring its journal.
        while configurationBusy {
            do { try await Task.sleep(nanoseconds: 20_000_000) }
            catch { preparingToQuit = false; return false }
        }
        do {
            if manager.hasRestoreSnapshot || pacSettings.enabled { try await disableWebsiteProxy() }
            pacServer.stop()
            pathMonitor.cancel(); monitorTask?.cancel(); BoundedCommand.cancelAll()
            return true
        } catch {
            preparingToQuit = false
            notice = "恢复流程未完成，已取消退出。请先处理恢复错误，再退出。"
            present(error)
            return false
        }
    }

    private func retainPACRevisions() {
        launchedPACApps = launchedPACApps.filter { manager.isRunning($0.value.0) }
        var retained = Set(launchedPACApps.values.map { $0.1 })
        if let currentPACURL, let revision = URLComponents(string: currentPACURL)?.queryItems?.first(where: { $0.name == "v" })?.value { retained.insert(revision) }
        pacContentStore.retain(retained)
    }
    func saveRule(_ input: String, action: RuleAction, match: RuleMatch, id: UUID? = nil, source: RuleSource = .user) async -> Bool {
        guard !configurationBusy, !preparingToQuit else { return false }
        configurationBusy = true; defer { configurationBusy = false }
        do {
            try ensureEditable()
            let domain = try WebsiteNormalizer.normalize(input)
            var candidate = configuration
            if let id, let other = candidate.manualRules.first(where: { $0.domain == domain && $0.match == match && $0.id != id }) {
                throw RoutingError.invalid("该域名和范围已有规则（\(other.domain)），请编辑已有规则")
            }
            let index = candidate.manualRules.firstIndex { id == nil ? $0.domain == domain && $0.match == match : $0.id == id }
            if let index {
                candidate.manualRules[index].domain = domain; candidate.manualRules[index].action = action
                candidate.manualRules[index].match = match; candidate.manualRules[index].enabled = true
                candidate.manualRules[index].modifiedAt = Date(); candidate.manualRules[index].source = source
            } else { candidate.manualRules.append(ManagedWebsite(domain: domain, match: match, action: action, source: source)) }
            candidate.manualRules.sort { $0.domain + $0.match.rawValue < $1.domain + $1.match.rawValue }
            try await commit(candidate, mode: activeMode)
            savedNotice(); refreshDecision(); return true
        } catch { handleConfigurationFailure(error); return false }
    }
    func setWebsiteEnabled(_ website: ManagedWebsite, enabled: Bool) {
        Task { await mutateRules { rules in if let i = rules.firstIndex(where: { $0.id == website.id }) { rules[i].enabled = enabled; rules[i].modifiedAt = Date() } } }
    }
    func removeWebsite(_ website: ManagedWebsite) { Task { await mutateRules { $0.removeAll { $0.id == website.id } } } }
    private func mutateRules(_ mutate: (inout [ManagedWebsite]) -> Void) async {
        guard !configurationBusy, !preparingToQuit else { return }; configurationBusy = true; defer { configurationBusy = false }
        do { try ensureEditable(); var candidate = configuration; mutate(&candidate.manualRules); try await commit(candidate, mode: activeMode); savedNotice(); refreshDecision() }
        catch { handleConfigurationFailure(error) }
    }
    private func ensureEditable() throws {
        if let configurationError { throw configurationError }
        guard websitePACStatus != .needsRestore else { throw RoutingError.invalid("请先恢复网络设置") }
    }
    private func savedNotice() { notice = activeMode == .off ? "已保存，开启分流后生效" : "配置已更新，必要时重新加载页面；PAC 参数启动的应用可能需要重启。" }
    func setAutomaticUpdates(_ enabled: Bool) {
        guard !configurationBusy, !preparingToQuit else { return }
        do { try ensureEditable(); var candidate = configuration; candidate.automaticUpdates = enabled; try manager.routingStore.save(candidate); configuration = candidate }
        catch { present(error) }
    }
    func updateRules() async {
        guard !updatingRules, !preparingToQuit, configurationError == nil else { return }
        let generation = updateGeneration
        updatingRules = true; defer { updatingRules = false }
        do {
            let snapshot = try await updater.update(proxyAvailable: quickcat.httpAvailable)
            let parsed = try await Task.detached(priority: .utility) { try snapshot.parse() }.value
            while configurationBusy { try await Task.sleep(nanoseconds: 50_000_000) }
            guard generation == updateGeneration, !preparingToQuit else { return }
            configurationBusy = true; defer { configurationBusy = false }
            try ensureEditable()
            var candidate = configuration; candidate.lastSuccessfulCheck = Date()
            let previous = snapshot.version == ruleCache?.current.version ? ruleCache?.previous : ruleCache?.current
            try await commit(candidate, mode: activeMode, rules: parsed, cache: RuleSetCache(current: snapshot, previous: previous))
            ruleError = nil; schedule.succeeded(at: Date()); savedNotice(); refreshDecision()
        } catch { if generation == updateGeneration { ruleError = "更新失败，继续使用现有规则：\(error.localizedDescription)"; schedule.failed(at: Date()) } }
    }
    func rollbackRules() async {
        guard !configurationBusy, !preparingToQuit, let previous = ruleCache?.previous else { return }
        configurationBusy = true; defer { configurationBusy = false }
        updateGeneration += 1
        await updater.cancel()
        do {
            try ensureEditable()
            let parsed = try await Task.detached(priority: .utility) { try previous.parse() }.value
            var candidate = configuration; candidate.automaticUpdates = false
            // Pause first so a crash cannot silently undo a requested rollback.
            try manager.routingStore.save(candidate)
            configuration = candidate
            try await commit(candidate, mode: activeMode, rules: parsed, cache: RuleSetCache(current: previous, previous: ruleCache?.current))
            ruleError = nil; notice = "已回退上一版本，自动更新已暂停。"; refreshDecision()
        } catch { handleConfigurationFailure(error) }
    }
    func cancelCheck() { checkGeneration += 1; checkTask?.cancel(); checkTask = nil; checking = false; checkResult = nil; checkDecision = nil; checkDomain = "" }
    func refreshDecision() { if !checkDomain.isEmpty { checkDecision = matcher.decision(host: checkDomain, mode: activeMode) } }
    func checkWebsite() {
        cancelCheck()
        do { checkDomain = try WebsiteNormalizer.normalize(checkInput) } catch { present(error); return }
        refreshDecision(); checking = true
        let domain = checkDomain, generation = checkGeneration
        let manualProxy = DomainRuleMatcher(manual: websites).decision(host: domain, mode: .manual).action == .proxy
        let proxyAvailable = quickcat.httpAvailable
        checkTask = Task {
            let result = await probe.check(domain: domain, skipDirect: manualProxy, proxyAvailable: proxyAvailable)
            guard !Task.isCancelled, generation == checkGeneration else { return }
            checkResult = result; checking = false
        }
    }
    func launchWithRules(_ application: ManagedApplication) async {
        do {
            guard isWebsiteProxyEnabled, !configurationBusy, !preparingToQuit, let currentPACURL else { throw RoutingError.invalid("请先开启网站分流") }
            configurationBusy = true; defer { configurationBusy = false }
            try await checkPAC(currentPACURL)
            guard !preparingToQuit else { return }
            try await manager.launch(application, usingProxy: false, pacURL: currentPACURL)
            if let revision = URLComponents(string: currentPACURL)?.queryItems?.first(where: { $0.name == "v" })?.value {
                launchedPACApps[application.id] = (application, revision)
            }
        } catch { present(error) }
    }
    func refreshQuickcat() async { quickcat = await manager.inspectQuickcat() }
    func checkConnection() async {
        guard !isBusy else { return }; isBusy = true; defer { isBusy = false }
        let report = await manager.diagnose(); quickcat = report.quickcat; systemProxyEnabled = report.systemProxyEnabled
        connections = report.connections; hasRunDiagnostics = true
    }
    private func handleConfigurationFailure(_ error: Error) {
        if websitePACStatus != .needsRestore && activeMode == .off { websitePACStatus = .failed(error.localizedDescription) }
        present(error)
    }
    private func present(_ error: Error) { errorMessage = error.localizedDescription; showingError = true }
    func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "选择应用"
        panel.prompt = "添加"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let application = try manager.application(from: url)
            guard !applications.contains(where: {
                $0.bundlePath == application.bundlePath
                    || ($0.bundleIdentifier != nil && $0.bundleIdentifier == application.bundleIdentifier)
            }) else { throw ProxyAppsError.duplicateApplication }
            applications.append(application)
            try manager.saveApplications(applications)
        } catch {
            present(error)
        }
    }

    func remove(_ application: ManagedApplication) {
        applications.removeAll { $0.id == application.id }
        do {
            try manager.saveApplications(applications)
        } catch {
            present(error)
        }
    }

    func launch(_ application: ManagedApplication, usingProxy: Bool) async {
        guard !isBusy else { return }
        if usingProxy && !quickcat.isAvailable {
            present(ProxyAppsError.quickcatUnavailable)
            return
        }
        isBusy = true
        do {
            try await manager.launch(application, usingProxy: usingProxy)
        } catch {
            manager.record(error)
            present(error)
        }
        isBusy = false
    }

    func icon(for application: ManagedApplication) -> NSImage {
        manager.icon(for: application)
    }

    func isChromiumApplication(_ application: ManagedApplication) -> Bool {
        manager.isChromiumApplication(application)
    }


}
