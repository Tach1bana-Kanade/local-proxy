import Foundation

public enum PACGenerator {
    public static func generate(websites: [ManagedWebsite]) -> String {
        let domains = enabledDomains(websites)
        let encoded = (try? JSONEncoder().encode(domains))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return """
        function FindProxyForURL(url, host) {
            host = host.toLowerCase();
            if (isPlainHostName(host) ||
                host === "localhost" ||
                host === "::1" ||
                dnsDomainIs(host, ".local") ||
                isInNet(host, "127.0.0.0", "255.0.0.0")) {
                return "DIRECT";
            }
            var proxyDomains = \(encoded);
            for (var i = 0; i < proxyDomains.length; i++) {
                var domain = proxyDomains[i];
                if (host === domain || dnsDomainIs(host, "." + domain)) {
                    return "PROXY 127.0.0.1:21081";
                }
            }
            return "DIRECT";
        }
        """
    }

    public static func shouldProxy(host: String, websites: [ManagedWebsite]) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard host != "localhost", !host.hasSuffix(".local"), !isLoopback(host) else { return false }
        return enabledDomains(websites).contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static func enabledDomains(_ websites: [ManagedWebsite]) -> [String] {
        Array(Set(websites.filter(\.enabled).map(\.domain))).sorted()
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "::1" || host == "127.0.0.1" || host.hasPrefix("127.")
    }
}
