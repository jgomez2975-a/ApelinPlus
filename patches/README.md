# patches/

`apelin-deb.yml` 在 clone 上游之后，会把这里的每个 `*.patch` 依次 `git apply`。

## 基线

**上游主仓 `owngoal-dev/Apelin`，tag `v0.4.7`。**

`wwg135/Apelin` 是它的 fork，停在 v0.3.7（2026-11-04 最后一次推送）。曾经按那个 fork 编过一次，出来的是 0.3.7，白跑一轮。换 URL 之前先查 `fork` 字段。

## 为什么用 patch 而不是 fork

fork 一份两千多个文件的仓库，上游一更新就得 rebase，而且改的每个文件都在 diff 里糊成一团。patch 只记录改了什么，上游怎么变都不影响 patch 的语义，冲突了 `--3way` 会明确指出哪一行对不上。

## 现有

| patch | 做什么 | 风险 |
|---|---|---|
| `0000-lower-ios-sdk-tier` | `IOS_SDK_TIER 27.1 → 26.5`，让 `macos-26` 镜像（Xcode 26.6）能过 `sdk-tier` | 低。只有代码真用了 iOS 27 API 才会炸，`xcodebuild` 会直接报 |
| `0001-local-features` | 四项功能 + 六屏界面：中转站标签与配色、上下文压缩修复、会话内搜索、余额查询与详情页、聊天页上下文条与检查器；版本 `0.4.7 (40) → 0.5.1 (44)` | 中。17 个文件、6 个新文件，见下 |

`0001` 曾是 `0001-endpoint-names`（标签）+ `0002-local-version`（版本号）两个补丁。四项功能里有三项改到了同一批文件（`ChatController`、`ModelProvidersController`），拆开生成时后一个补丁的上下文会依赖前一个已应用，合并成一个补丁反而更稳。

### 0001 做了什么

#### 1. 中转站标签

上游 0.4.7 已经支持多个 OpenAI-compatible 端点（`openaiCompatible.2` … `.99`），但**列表里只有 host 一行小字**，表单里只有 token 和 URL 两个输入框，没有任何地方能写"这是云雾还是老张的站"。

- **列表**：标题是你起的名字，host 仍在下面那一行；没起名的仍显示 `OpenAI-Compatible API`
- **搜索**：名字和 host 都能搜到
- **`…` 菜单**：多一项 `Rename`（只对 OpenAI-compatible 端点出现）
- **端点表单**：最上面多一格 `Name (Optional)`，紧挨在 token 和 URL 之前
- **聊天里的模型菜单**：按名字分组，没起名的回落到 host
- **登出确认框**：先说名字，再说 host

名字只存在本 App 的 `UserDefaults`（键 `provider.names`），**不进 keychain、不进凭证、不发给 apelin-agent 或 kwwk**。键是 `provider.rawValue`（`openAICompatible.2` 这种），每个端点唯一。

新增文件 `Apelin/Interface/Settings/Accounts/ProviderLabel.swift`。

#### 2. 上下文压缩修复

报错长这样：

```
context is too large and compaction failed:
compaction left 120801 tokens, above the recovery target of 78643
```

78643 这个数字是三个默认值乘出来的（`Agent.swift` 的 `automaticRecoveryTarget`）：

```
target = min(window × threshold × recoveryRatio, inputTokens)
       = min(131072 × 0.75 × 0.80, 98304)
       = min(78643, 98304) = 78643
```

`inputTokens = window − window/4`（`AgentRequestBudget`，自定义模型没有 automatic limit 时按窗口 1/4 留输出余量）。

kwwk 压缩失败时会缩小"保留的近期尾部"重试，但 `maxSummaryAttempts` 默认只有 **2**，两轮压不到位就直接把错误抛给用户。

改 `NativeCompactionFallback.configuration`：

| 参数 | 默认 | 改成 | 为什么 |
|---|---|---|---|
| `maxSummaryAttempts` | 2 | 8 | 每轮尾部减半，8 轮才够把长会话走下来；尾部降到一条消息后不再变化，多余轮次不产生开销 |
| `recoveryRatio` | 0.8 | 0.95 | target 提到 93388（仍 < 98304，压出来的结果 provider 收得下） |
| `keepRecentTokens` | 20000 | 6000 | 第一轮就从更靠近答案的地方开始，不浪费一轮压 20k 尾部 |
| `summaryWordTarget` | 900 | 600 | 每份摘要本身就短一点 |

另加兜底：压缩失败且原因是"压不下去"时，先用 `AgentContextCompactor.shakeToolOutputs` 把超长 tool result 折成占位符（纯本地操作，不花 token），再压一次。

#### 2b. 光调参数救不了，原因在 planner

上面那四个参数是第一版的做法。它们能让"整体偏大、但切得动"的会话压下来，**救不了截图里那一条**，两个原因：

**一、切点被钉死。** `CompactionPlanner.plan` 里：

```swift
if let protectedUserStart, suffixStart > protectedUserStart {
    suffixStart = protectedUserStart      // 整个未回答的 turn 原地保留
    suffixTokens = estimatedTokens(in: Array(messages[suffixStart...]))
}
```

一个读了几个大文件的 turn，其全部 tool result 都排在 `protectedUserStart` 之后，于是整轮被无条件保留。`keepRecentTokens` 缩到多少，`plan.firstKeptMessageIndex` 都是同一个值，`ContextCompactionPipeline` 里这行

```swift
guard previousCut != plan.firstKeptMessageIndex else { break }
```

第一轮就退出 —— `maxSummaryAttempts` 配成 8 也是 8 次计划同一个替换，最后一次的 `tokensAfter` 被原样报出来（截图里的 120801）。

**二、走的不是这条路。** 这条报错来自 `Agent.prompt` 内部的 preflight（`AgentContextPreflightError.compactionFailed`），不经过 `AgentSession.runCompaction`（那是手动压缩和空闲压缩的入口）。只在 `runCompaction` 里加兜底，对发送时被拒这种情形完全无效。

能改的是 transcript 本身，而不用模型就能缩小的只有 tool output。所以补了两处：

**发送前** —— `AgentSession.prompt` 里的 `foldToolOutputsPastTheInputBudget()`。只在 `currentUsage > window − window/4 − 4000` 时动手，也就是这条消息本来就会被拒；装得下的会话一个字节都不动。三档折叠，每档之后重新量，够了就停：

| 档 | 折叠什么 |
|---|---|
| 8000 字符 | 只收真正的大块（整文件读取、长 diff） |
| 2000 字符 | 连中等输出一起收 |
| 1000 字符 | kwwk `/shake` 的默认值，等于把工具输出全部作废 |

`window − window/4` 是 kwwk `AgentRequestBudget.inputTokens` 的算法（自定义模型没有 automatic limit 时按窗口 1/4 留输出余量）；再减 4000 是因为 `currentUsage(messages:)` 只数消息，不含系统提示和工具声明。

**压缩兜底** —— `runCompaction` 同样的三档，每档后重压一次。失败就**回滚** transcript：不能既没压成，又把工具输出永久扔掉。非体积原因的失败（比如 `refusedTooFewMessages`）立即回滚返回。

折叠后的 tool result 长这样，模型能看出这里被省略了、原来多大：

```
[tool result elided to reclaim context — was 214883 chars]
```

这是有代价的：被折掉的输出模型再也看不到，之后要靠重新读取。所以只在"这条消息本来就发不出去"时才动，且从最温和的一档试起。

#### 3. 会话内搜索

会话 `…` 菜单第一项 `Search`。打开是一个搜索页，列出所有正文（用户消息 + 回复，不含活动行和压缩摘要）命中关键词的消息，显示命中处的上下文片段；点一条打开全文页，可整段复制。

用 UISearchController，搜索时忽略大小写和变音符号。新增文件 `Apelin/Interface/Chats/ChatSearchController.swift`。

#### 4. 余额查询

OpenAI-compatible 端点的 `…` 菜单多一项 `Balance`。点开后按 host 依次尝试：

- DeepSeek：`/user/balance`
- OpenRouter：`/api/v1/credits`
- 其余：OpenAI 计费对 `/v1/dashboard/billing/subscription` + `/v1/dashboard/billing/usage`（`total_usage` 单位是美分）

密钥通过 `agentAPIConfiguration` 读回（和编辑表单同一条路），只发往它自己的服务商，不落盘。中转站把余额藏在登录页后面时，key 会拿到 401/404，此时提示"该服务商未提供余额信息"，而不是当成 key 失效。

新增文件 `Apelin/Interface/Settings/Accounts/ProviderBalance.swift`。

#### 5. 界面改版

第一版只做了功能，界面一行没动：列表还是每行一个系统 cell，余额是一个 alert，聊天页没有任何地方说上下文有多满。这一节是设计稿那六屏，用 UIKit 重做的（主工程是 `TableController: UITableViewController`，不是 SwiftUI）。

**先前那份 SwiftUI 实现（`Sources/ApelinPlusUI/`，1398 行）没有接进主工程**——`Package.swift`、`Makefile`、工程文件都没有引用它，等于没编译。现在的界面全在 `Apelin/Interface/` 下。

| 屏 | 落到哪 |
|---|---|
| ① 服务商列表 | `ProviderAccountCell` + `ProviderTint` + `ModelProvidersController` |
| ② 编辑表单配色 | `ProviderKeyFormController` 的 Color 行 |
| ③ 余额详情 | `ProviderBalanceScreen` |
| ④ 聊天页上下文条 | `ContextMeterView` + `ChatController` |
| ⑤ 搜索命中高亮 | `ChatSearchController` |
| ⑥ 上下文检查器 | `ChatContextController` + `ChatContextUsage` |

**① 列表**：29pt 圆角渐变方标，取名字首字（没起名的取 host 首字母，否则每个都显示 `O`）；标题是名字，副标题是 host（中转站不写平台名，方标已经说明了）；右侧是余额胶囊，绿=充足、橙=低于 5、省略号=正在问。颜色按 `rawValue` 稳定散列分配（用求和不用 `hashValue`，Swift 的哈希每进程随机，否则每次启动都换色）。余额**串行**问，一次一个端点——六个请求并发打别人的服务器容易被限流；答案在这个屏幕的生命周期内缓存。

**② 表单**：多一行 Color，右侧色块点开是 5 种配色 + `Default`（交回自动分配）。选中即存（`provider.tones`，`UserDefaults`），因为它不是凭据，也没有"放弃"可言。

**③ 余额页**：从列表 `…` → Balance 推入。大号剩余金额 + 进度条 + `已用 / 总额` 两个数字，右上角 Refresh。查不到时明说"该服务商未提供余额信息"，不当成 key 失效。

**④ 上下文条**：导航栏下沿一条 2pt 细线，占窗口比例。低于 50% 不显示（有意思但不可操作），75% 转橙，90% 转红。它加在 `view` 上并 `bringSubviewToFront`，不是 `messageList` 的子视图——列表在换会话时会整个重建，子视图会跟着被扔掉。

**⑤ 搜索**：命中词在片段里高亮（`tintColor` 18% 底色 + tint 文字），每行左侧标出是用户说的还是模型说的。

**⑥ 检查器**：`…` → Context。总量 / 128k、进度条、按角色拆分（提示 / 回复 / 工具 / 活动）。**数字是估算**：App 侧看不到系统提示、工具目录和 provider 自己的账，而 `TokenEstimate`（`ApelinProtocol` 里的共享估算器，4 个 ASCII 字符≈1 token、其它字符 1:1）就是 agent 数流式输出用的那一个，所以两边口径一致。页面底部写明 "Estimated"。

窗口固定按 128k 算（kwwk 对未知模型的默认值）——真实窗口若是 200k，条会偏高地报占比，这是已知偏差。

### 关于本地化

`build` 之后会跑 `check-catalog-keys.py`（编译器抽出的字面量必须在 catalog 里）和 `check-translations.py`（每个键必须有 12 种语言）。

- 标签、搜索用到的全是**已有键**：`Name`、`Rename`、`Save`、`Cancel`、`Search`、`No Results`、`Contents`、`Copy`、`%@ (Optional)`、`%@ Options`、`Sign Out of %@?`
- 新增 12 个键，都已连同 12 种语言写进 `Apelin/Resources/Localizable.xcstrings`：
  - `Balance`、`This endpoint does not report a balance.`
  - `Color`、`Context`、`Messages`、`Tools`、`System Prompt`、`Estimated`、`Refresh`、`Prompt`、`Reply`、`Activity`

`presentNotice` 的 title/message 参数是 `String.LocalizationValue`，要传**英文字面量**让 AlertController 自己去查 catalog，不要传已本地化的 `String(localized:)`。

新增的 3 个文件都在 `Apelin/` 下，工程用 `PBXFileSystemSynchronizedRootGroup`（objectVersion 77），自动进 target，不需要改 `project.pbxproj`。

## 生成方式

改完 `apelin-047/`（v0.4.7 的稀疏克隆）之后：

```bash
cd apelin-047
git add -A
git diff --cached > ../apelin-plus/patches/0001-local-features.patch
```

**用 `--cached` 而不是 `git diff`**：新文件不 `add` 就不进 diff。

**不要加 `-c core.autocrlf=false`。** 本机 `core.autocrlf=true`，绕过它会让 CRLF 工作区和 LF 索引的差异被算成全文件重写，补丁会膨胀好几倍。

## 验证

`git archive v0.4.7` 导出一份干净树，`git init` 后 `git apply --check` 两个补丁，都 `OK`。再实际 apply 一遍，确认：

- `Configuration/Version.xcconfig` 落到 `0.5.1` / `44`
- 六个新文件到位
- `Localizable.xcstrings` 仍是合法 JSON，1029 个键，新增的 12 个键 12 种语言齐全
