import SwiftUI
import AppKit
import LocalProxyCore

struct RulesView: View {
    @EnvironmentObject private var controller: ProxyController
    @State private var domainInput = ""
    @State private var domainMatchType: DomainMatchType = .suffix

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("代理规则").font(.title2.bold())
                    Text("只有这里启用的应用或网站使用 Quickcat，其余流量直连。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    controller.chooseApplication()
                } label: {
                    Label("添加应用", systemImage: "plus.app")
                }
            }

            HStack {
                Picker("匹配方式", selection: $domainMatchType) {
                    ForEach(DomainMatchType.allCases, id: \.self) { type in
                        Text(domainMatchLabel(type)).tag(type)
                    }
                }
                .frame(width: 130)

                TextField(domainPlaceholder, text: $domainInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addDomain)
                Button("添加网站", action: addDomain)
                    .disabled(domainInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            List {
                Section("应用") {
                    if controller.configuration.applicationRules.isEmpty {
                        Text("尚未添加应用").foregroundStyle(.secondary)
                    }
                    ForEach(controller.configuration.applicationRules) { rule in
                        RuleRow(
                            title: rule.displayName,
                            subtitle: rule.executablePath,
                            symbol: "app",
                            enabled: rule.enabled,
                            onToggle: { controller.setApplicationRule(rule.id, enabled: $0) },
                            onDelete: { controller.removeApplicationRule(rule.id) }
                        )
                    }
                }
                Section("网站") {
                    if controller.configuration.domainRules.isEmpty {
                        Text("尚未添加网站").foregroundStyle(.secondary)
                    }
                    ForEach(controller.configuration.domainRules) { rule in
                        RuleRow(
                            title: rule.value,
                            subtitle: domainMatchLabel(rule.match),
                            symbol: "globe",
                            enabled: rule.enabled,
                            onToggle: { controller.setDomainRule(rule.id, enabled: $0) },
                            onDelete: { controller.removeDomainRule(rule.id) }
                        )
                    }
                }
            }
            .listStyle(.inset)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            Text("规则修改会在下次启动时生效。运行中请先停止，再重新开启。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private func addDomain() {
        controller.addDomainRule(domainInput, match: domainMatchType)
        if !controller.showingError { domainInput = "" }
    }

    private var domainPlaceholder: String {
        switch domainMatchType {
        case .exact: return "精确域名，例如 api.example.com"
        case .suffix: return "域名后缀，例如 example.com"
        case .wildcard: return "通配符，例如 *.example.com"
        case .ipCIDR: return "IP 或 CIDR，例如 203.0.113.8/32"
        }
    }

    private func domainMatchLabel(_ type: DomainMatchType) -> String {
        switch type {
        case .exact: return "精确域名"
        case .suffix: return "域名后缀"
        case .wildcard: return "通配符域名"
        case .ipCIDR: return "IP / CIDR"
        }
    }
}

private struct RuleRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let enabled: Bool
    let onToggle: (Bool) -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 26)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { enabled }, set: onToggle))
                .labelsHidden()
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }
}
