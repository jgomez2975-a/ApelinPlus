# ApelinPlus — 接入说明

这个包只做三件事，全部不依赖 kwwk、不依赖 `ApelinProtocol`：

| 文件 | 作用 | 对应你的需求 |
|---|---|---|
| `ProviderInstance.swift` + `ProviderInstanceStore.swift` | 服务商「实例」模型：标签、颜色、分组、置顶、余额设置，JSON 持久化 + 老账号迁移 | ② 加标签、多个中转站分得清 |
| `BalanceAdapters.swift` | 5 个余额接口适配器：New-API / One-API / OpenRouter / DeepSeek / OpenAI | ⑤ 查余额 |
| `BalanceService.swift` + `BalanceFormatting.swift` | 自动探测、缓存、并发去重、分档、文案 | ⑤ 查余额 |
| `BalanceCredentialStore.swift` | 余额查询用的 token 单独进 keychain，不落 JSON | ⑤ |

---

## 一、先跑测试

```bash
cd apelin-plus
swift test
```

我这边是 Windows，没有 Swift 工具链，**这套代码没有编译验证过**。测试写了 20 个用例，覆盖端点解析、五种响应格式、401 映射、分档边界、迁移幂等、损坏文件兜底。有任何编译错误，把报错贴给我，我改。

---

## 二、加进 Xcode 工程

`Apelin.xcodeproj` → File ▸ Add Package Dependencies ▸ Add Local… → 选 `apelin-plus` 目录 → 加到 **Apelin** target。

---

## 三、接余额（③⑤，零风险，先上这个）

`Apelin/Interface/Settings/Accounts/ModelProvidersController.swift`：

```swift
// 文件顶部
import ApelinPlus
```

加三个属性：

```swift
private let instances = ProviderInstanceStore()
private let balances = BalanceService()
/// instanceID → Base URL 与该实例的模型 key，刷新时用。
private var routing: [UUID: (baseURL: String, apiKey: String)] = [:]
```

`regroup()` 里，把 `accounts` 换成实例：

```swift
@objc private dynamic func regroup() {
    guard loaded else { sections = [(.status, [.status(.loading)])]; dataSource.update(sections); return }
    Task { @MainActor in
        // 老账号迁移：签过的平台各补一个实例，标签留空显示平台名。
        let signedIn = accounts.filter(\.signedIn).map(\.provider.rawValue)
        let subscriptions = Set(accounts.filter { !$0.isAPIKeyAccount }.map(\.provider.rawValue))
        try? await instances.migrate(signedInProviderIDs: signedIn, subscriptionProviderIDs: subscriptions)

        let list = await instances.all(platformNames: platformNames)
        // 只用实例出「已连接」区，没实例的平台仍走原来的「可添加」区。
        self.sections = …
        self.dataSource.update(self.sections)
        await self.refreshVisibleBalances(list)
    }
}

private var platformNames: [String: String] {
    Dictionary(uniqueKeysWithValues: accounts.map { ($0.provider.rawValue, $0.provider.displayName) })
}
```

`accountCell` 换成实例行：

```swift
private func instanceCell(_ instance: ProviderInstance) -> UITableViewCell {
    let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
    var content = UIListContentConfiguration.subtitleCell()
    content.text = instance.displayName(platformName: platformNames[instance.providerID] ?? instance.providerID)

    // 副标题：平台名 · 域名 · 计划
    var parts = [platformNames[instance.providerID] ?? instance.providerID]
    let host = routing[instance.id].flatMap { BalanceEndpoint(baseURL: $0.baseURL)?.host }
    if let host { parts.append(host) }
    if let snapshot = cachedBalance(instance.id) {
        if let plan = snapshot.reading?.planName, !plan.isEmpty { parts.append(plan) }
    }
    content.secondaryText = parts.joined(separator: " · ")
    content.secondaryTextProperties.color = .secondaryLabel

    content.image = icon(for: instance)   // 有平台图标用图标，没有就用色板 + 首字母
    cell.contentConfiguration = content
    cell.accessoryView = balancePill(instance)   // 没有余额就挂 ⋯ 菜单
    return cell
}
```

余额胶囊：

```swift
private func balancePill(_ instance: ProviderInstance) -> UIView {
    guard instance.balance.enabled, let snapshot = cachedBalance(instance.id) else {
        return menuButton(instance)   // 原 ⋯ 菜单
    }
    let text = BalanceText.pill(snapshot, warningThreshold: instance.balance.warningThreshold)
    var config = UIButton.Configuration.plain()
    config.title = text
    config.image = nil
    config.contentInsets = .init(top: 3, leading: 8, bottom: 3, trailing: 8)
    config.background.cornerRadius = 7
    switch snapshot.tier(warningThreshold: instance.balance.warningThreshold) {
    case .healthy: config.baseForegroundColor = .systemGreen
    case .low:     config.baseForegroundColor = .systemOrange
    case .exhausted, .failed: config.baseForegroundColor = .systemRed
    case .unknown: config.baseForegroundColor = .secondaryLabel
    }
    let button = UIButton(configuration: config)
    button.titleLabel?.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
    button.showsMenuAsPrimaryAction = true
    button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
        completion(self?.instanceActions(instance) ?? [])
    }])
    return button
}
```

刷新：

```swift
private func refreshVisibleBalances(_ list: [ProviderInstance]) async {
    let snapshots = await balances.refreshAll(
        instances: list.filter { $0.balance.enabled },
        baseURL: { routing[$0]?.baseURL ?? "" },
        apiKey: { routing[$0]?.apiKey ?? "" },
    )
    guard !snapshots.isEmpty else { return }
    dataSource.update(sections)   // 让行重画
}
```

`routing` 的数据来源有两处：`AgentAccount.account` 给的是 endpoint host，不够拼 URL；完整 Base URL 要从 `ApelinService.app.agentAPIConfiguration(provider:)` 取（它只对 `isAPIKeyAccount` 有效），模型 key 是 `values["apiKey"]`。所以在 `load()` 里：

```swift
for account in list.accounts where account.isAPIKeyAccount {
    guard let configuration = try? await ApelinService.app.agentAPIConfiguration(provider: account.provider),
          let baseURL = configuration.values["baseUrl"],
          let apiKey = configuration.values["apiKey"]
    else { continue }
    // 第一实例（最老的那个）拿主账号的配置
    if let instance = await instances.primary(of: account.provider.rawValue) {
        routing[instance.id] = (baseURL, apiKey)
    }
}
```

> 注意 `AgentSignInField.baseURL` 的 wire 名是 `baseUrl`（小写 d），`AccountDesk.apiConfiguration` 按这个 key 回值。

---

## 四、硬骨头：真正的多实例凭证

上面那一套能让你**给每个已签平台改标签、看余额**，但**同一个平台仍然只有一个 keychain 条目**。三个「OpenAI 兼容」中转站，第二、第三个进不去。

原因在读过的两处：

- `AccountDesk.list()`：`for provider in AgentProvider.signInOrder`，一个 provider 产一个 `AgentAccount`
- `AccountDesk` 全篇用 `provider.storeID` 做 keychain key

**好消息**：`CredentialSource.store(_:for:)` 收的是 `String`，不是枚举，所以 `"openai-compatible@<uuid>"` 在类型上是通的。而且 `AgentSignInMethod.apiKey` 分支**根本不走 `KWWKSignIn.login`**——它只构造 `OAuthCredentials` 然后 `store.store`。这意味着**多个中转站这种纯 API-key 场景完全避开 OAuth 流程**，是最容易做的一块。

### 改动清单

**1. `ApelinKit/Sources/ApelinProtocol/Operations/AgentSignIn.swift`**

每个请求加一个可选字段（可选 = 向后兼容，老客户端不受影响）：

```swift
public struct AgentAccount: Codable, Sendable, Equatable {
    // …原有字段…
    /// 多实例标识；nil 表示该平台的第一个实例（沿用裸 storeID）。
    public var instanceID: String?
}
```

同样给 `AgentSignInRequest`、`AgentSignOutRequest`、`AgentAPIConfigurationRequest`、`AgentModelListRequest`、`AgentModelActivateRequest` 各加 `public var instanceID: String?`。

**2. `ApelinAgentWorker/SignIn/AccountDesk.swift`**

```swift
/// 多实例的 keychain 键：第一个实例用裸 id（老账号原地不动），
/// 后续实例追加 `@<uuid>`。
static func storeID(_ provider: AgentProvider, _ instanceID: String?) -> String {
    guard let instanceID, !instanceID.isEmpty else { return provider.storeID }
    return "\(provider.storeID)@\(instanceID)"
}
```

`list()` 改成：先按裸 storeID 产主实例，再枚举 `store.providerIds()` 里前缀为 `"\(provider.storeID)@"` 的条目各产一个。其余 `signOut / credentials(for:) / apiConfiguration / models / activateModels` 把 `provider.storeID` 换成 `Self.storeID(provider, request.instanceID)`。

**3. 会话层**

`ChatController.swift:690` 的 `selection(of:in:)` 是入口。模型选择要能表达「哪个实例的哪个模型」，而不是「哪个平台的哪个模型」。这块改动最散，得一处一处过。

### 动手之前先验证一件事

**kwwk 是否接受任意 store id。** 从用法看是接受的（`providerIds()` 返回 `[String]`），但 kwwk 内部可能对 id 做白名单校验。验证方法，5 分钟：

```bash
cd Packages/ApelinAgent
# 在 AccountDesk 里临时加一个调试方法，用假 id 存一次再读回来
swift test --filter AccountDeskTests
```

或者在真机上：签进一个 OpenAI 兼容中转站，然后

```bash
# keychain 里应当出现 openai-compatible 这一条
security dump-keychain | grep -A2 "wiki.qaq.apelin.agent"
```

确认 kwwk 的 `CredentialSource` 实现是否把 id 当不透明字符串。**如果它做白名单校验，多实例就只剩「在协议层加 provider case」这一条路**——那是另一个量级的改动（每个中转站得变成一个 provider，`AgentProvider` 枚举会爆炸），不推荐。

---

## 五、已知限制

1. **没编译验证**。见第一节。
2. **余额宿主的 keychain 访问组**。`BalanceCredentialStore` 默认 service 是 `wiki.qaq.apelin.balance`，在 App 进程里没有访问组限制；如果要和 worker 共享，得加 `kSecAttrAccessGroup` 并在 entitlements 里声明同一个组。目前不需要。
3. **New-API 余额拿不到时会返回 `.notConfigured` 而不是报错**，因为 `sk-` key 读不了余额，必须用户单独填站点 token。设置页要把这个提示写清楚，否则用户会以为是 bug。
4. **OpenAI 官方 billing 接口对多数 key 返回 401**，适配器如实报 `Key rejected`，不会假报 0。
5. `ProviderInstance.storeID(isFirstOfProvider:)` 只是**约定**，真正决定用哪个 keychain key 的是 worker。两边必须用同一套规则，否则登录进去了但列表读不到。

---

## 六、下一步

按这个顺序推，每步都能单独验收：

1. `swift test` 通过（你跑，我修）
2. 接余额进 `ModelProvidersController`（第三节），能看到胶囊
3. 实例编辑表单（标签 / 颜色 / 分组）
4. 余额详情页 + 7 日柱图
5. **凭证多实例**（第四节），先验证 kwwk 的行为再动手
6. 上下文诊断 + 压缩前工具输出截断（那个报错的真正解法）
7. 会话内搜索
