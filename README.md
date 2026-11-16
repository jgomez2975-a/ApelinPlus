# ApelinPlus

> Apelin 的多实例服务商、余额查询与余额展示层。独立 SPM 包，不依赖 `ApelinProtocol`，不碰 KWWK。
>
> 上游：<https://github.com/wwg135/Apelin>（MIT）
> 本包：MIT

这个仓库存在的唯一目的是**在没有 Mac 的机器上也能验证 Swift 代码能编译**。代码推上来之后，GitHub 的 macOS runner 会跑 `swift test`，红了就贴日志给我。

---

## 包里有什么

| 文件 | 作用 |
|---|---|
| `ProviderInstance.swift` | 实例模型。一个"服务商"不再等于一个 `AgentProvider` 枚举值，而是一条带标签、配色、分组、置顶、余额设置的记录 |
| `ProviderInstanceStore.swift` | 实例的持久化。单文件 JSON、原子写、损坏文件挪走不覆盖、老账号迁移幂等 |
| `BalanceAdapters.swift` | 五个真实余额接口：New-API、One-API、OpenRouter、DeepSeek、OpenAI Billing。含端点推导（`/v1` 剥不剥、子路径保不保） |
| `BalanceService.swift` | 探测顺序、缓存、按实例去重并发、代数计数器防"删掉的实例被请求复活" |
| `BalanceCredentialStore.swift` | 中转站余额要的 session token + user id，单独进 keychain，不落 JSON |
| `BalanceFormatting.swift` | 余额怎么读：`¥42.80`、`$3.12`、分档、详情页行 |
| `Sources/ApelinPlusUI/` | SwiftUI 层，独立 target：服务商列表（标签/配色/分组/搜索/余额胶囊）、实例编辑表单、余额详情页 |
| `Tests/` | 25 个用例：端点解析、五种响应格式、401 映射、分档边界、迁移幂等、损坏文件 |

UI 是独立 target，`ApelinPlus` 里没有一行 `import SwiftUI`——worker 和测试跑在没有窗口服务的环境里也不会被拖进来。

---

## CI 三个 job

| job | 干什么 | 红了说明什么 |
|---|---|---|
| `swift test (macOS 15 / Swift 6)` | `swift build --build-tests` + `swift test` | 逻辑或类型错误。这是唯一的门禁 |

当前状态（2026-11-16 实测）：三个 job 全绿，25 个测试 0 失败，UI 层 1398 行在 iOS 与 macOS 两端都编译通过。
| `compile for iOS device (arm64)` | 用 iphoneos SDK 编 arm64 slice | macOS 能过但 iOS 不能过 —— 通常是 `Security` 或 `Foundation` 的平台差异 |
| `strict concurrency warnings` | 开 `-strict-concurrency=complete -warn-concurrency` 抓警告 | 不阻塞，只列出来。Swift 6 语言模式已经把大部分变成错误了，这个是补漏 |

第一个 job 绿了就等于代码可用。第二个绿了才能往 Apelin 里塞。

macOS runner 是免费额度里最贵的（按 10 倍分钟计费）。公开仓库无限量；私有仓库 2000 分钟/月额度 ≈ 200 分钟 macOS 实际时长，这个包的 CI 一轮约 2–3 分钟，够跑六七十次。

---

## 本地跑（有 Mac 的话）

```bash
swift test
```

没有 Mac 就跳过这一节，看 `PROVISION.md`。

---

## 怎么把它接进 Apelin

看 `INTEGRATION.md`。里面按"先验证什么、再改哪里"的顺序排了，其中第一节是个必须先做的验证，不做完后面全是空中楼阁。

---

## 许可

MIT，跟上游一致。
