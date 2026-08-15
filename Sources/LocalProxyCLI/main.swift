import Foundation
import LocalProxyCore
import Security
import Darwin

enum CLIError: LocalizedError {
    case usage(String)
    case fileExists(String)
    case randomGenerationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .usage(let message): return message
        case .fileExists(let path): return "文件已存在，不会覆盖：\(path)"
        case .randomGenerationFailed(let status): return "无法生成安全随机令牌（OSStatus \(status)）"
        }
    }
}

@main
struct LocalProxyCLI {
    static func main() {
        do {
            try run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("错误：\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func run(_ arguments: [String]) throws {
        guard let command = arguments.first else { throw CLIError.usage(help) }
        switch command {
        case "init":
            let path = arguments.dropFirst().first ?? "localproxy.json"
            try initialize(path: path)
        case "validate":
            guard let path = arguments.dropFirst().first else { throw CLIError.usage("用法：localproxy validate <rules.json>") }
            let configuration = try load(path: path)
            try RuleNormalizer.validate(configuration)
            print("规则有效：\(configuration.domainRules.count) 条网站规则，\(configuration.applicationRules.count) 条应用规则")
        case "generate":
            guard arguments.count >= 3 else { throw CLIError.usage("用法：localproxy generate <rules.json> <mihomo.yaml>") }
            let configuration = try load(path: arguments[1])
            let secret = try randomSecret()
            let yaml = try MihomoConfigGenerator().generate(from: configuration, apiSecret: secret)
            try writeNewFile(yaml, path: arguments[2], permissions: 0o600)
            print("已生成 Mihomo 配置：\(arguments[2])")
            print("安全提示：配置包含随机控制令牌，权限已设为 0600；TUN 尚未启动。")
        case "diagnose":
            let path = arguments.dropFirst().first ?? "localproxy.json"
            let configuration = try load(path: path)
            diagnose(configuration)
        case "help", "--help", "-h":
            print(help)
        default:
            throw CLIError.usage("未知命令：\(command)\n\n\(help)")
        }
    }

    static func initialize(path: String) throws {
        let sample = LocalProxyConfiguration(domainRules: [
            DomainRule(value: "example.com", match: .suffix, action: .proxy, enabled: false),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(sample)
        guard let text = String(data: data, encoding: .utf8) else { return }
        try writeNewFile(text + "\n", path: path, permissions: 0o600)
        print("已创建规则文件：\(path)")
    }

    static func load(path: String) throws -> LocalProxyConfiguration {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(LocalProxyConfiguration.self, from: data)
    }

    static func writeNewFile(_ text: String, path: String, permissions: Int16) throws {
        let fd = path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL, mode_t(permissions)) }
        if fd < 0 {
            if errno == EEXIST { throw CLIError.fileExists(path) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }

        let data = Data(text.utf8)
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let count = Darwin.write(fd, baseAddress.advanced(by: written), rawBuffer.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                written += count
            }
        }
    }

    static func diagnose(_ configuration: LocalProxyConfiguration) {
        let probe = PortProbe()
        let socks = probe.canConnect(host: configuration.upstream.host, port: configuration.upstream.socksPort)
        let http = probe.canConnect(host: configuration.upstream.host, port: configuration.upstream.httpPort)
        let quickcatExists = FileManager.default.isExecutableFile(atPath: configuration.quickcatExecutablePath)
        let mihomoPath = configuration.mihomoExecutablePath ?? findExecutable(named: "mihomo")

        print("Quickcat 可执行文件：\(quickcatExists ? "存在" : "未找到")")
        print("SOCKS5 \(configuration.upstream.host):\(configuration.upstream.socksPort)：\(socks ? "可连接" : "不可连接")")
        print("HTTP   \(configuration.upstream.host):\(configuration.upstream.httpPort)：\(http ? "可连接" : "不可连接")")
        print("Mihomo：\(mihomoPath ?? "未安装或未配置")")
        print("SOCKS5 UDP：\(configuration.upstream.udpEnabled ? "用户已确认启用" : "尚未验证，生成配置默认关闭")")
    }

    static func findExecutable(named name: String) -> String? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        return paths.map { String($0) + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func randomSecret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw CLIError.randomGenerationFailed(status) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static let help = """
    localproxy — 局部代理阶段 0 配置工具

    命令：
      init [rules.json]                    创建安全的示例规则文件
      validate <rules.json>                校验规则
      generate <rules.json> <mihomo.yaml>  生成 Mihomo TUN 配置（不启动）
      diagnose [rules.json]                检查 Quickcat 端口和 Mihomo
    """
}
