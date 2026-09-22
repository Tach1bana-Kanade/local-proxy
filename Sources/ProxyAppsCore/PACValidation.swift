import Foundation
import JavaScriptCore

public enum PACValidation {
    // Chromium checks the uncompressed script; HTTP gzip does not evade this bound.
    public static let maximumBytes = 1_048_575

    public static func validate(_ content: String) throws {
        guard content.utf8.count <= maximumBytes else {
            throw RoutingError.invalid("PAC 超过浏览器允许的 1 MiB，配置未应用；继续保留原规则。请减少手动规则或回退规则库。")
        }
        guard let context = JSContext() else { throw RoutingError.invalid("无法创建 PAC 校验环境") }
        context.evaluateScript(content)
        guard context.exception == nil,
              let function = context.objectForKeyedSubscript("FindProxyForURL"), !function.isUndefined,
              function.call(withArguments: ["https://localhost/", "localhost"])?.toString() == "DIRECT",
              context.exception == nil else {
            throw RoutingError.invalid("PAC JavaScript 执行校验失败，配置未应用")
        }
    }

    public static func compile(mode: RoutingMode, manual: [ManagedWebsite], automatic: [DomainRule] = []) throws -> String {
        let content = PACGenerator.generate(mode: mode, manual: manual, automatic: automatic)
        try validate(content)
        return content
    }
}
