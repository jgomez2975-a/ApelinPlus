# patches/

`apelin-deb.yml` 在 clone 上游之后，会把这里的每个 `*.patch` 依次 `git apply --3way`。

## 基线

**上游主仓 `owngoal-dev/Apelin`，tag `v0.4.7`。**

`wwg135/Apelin` 是它的 fork，停在 v0.3.7（2026-11-04 最后一次推送）。曾经按那个 fork 编过一次，出来的是 0.3.7，白跑一轮。换 URL 之前先查 `fork` 字段。

## 为什么用 patch 而不是 fork

fork 一份两千多个文件的仓库，上游一更新就得 rebase，而且改的每个文件都在 diff 里糊成一团。patch 只记录改了什么，上游怎么变都不影响 patch 的语义，冲突了 `--3way` 会明确指出哪一行对不上。

## 现有

| patch | 做什么 | 风险 |
|---|---|---|
| `0000-lower-ios-sdk-tier` | `IOS_SDK_TIER 27.1 → 26.5`，让 `macos-26` 镜像（Xcode 26.6）能过 `sdk-tier` | 低。只有代码真用了 iOS 27 API 才会炸，`xcodebuild` 会直接报 |
| `0001-endpoint-names` | 服务商可以起名字，多个中转站不再只能靠 host 区分 | 中。四个界面文件 + 一个新文件，见下 |
| `0002-local-version` | `0.4.7 (40) → 0.4.8 (41)` | 低。只是为了让 `dpkg -i` 当成升级，不是重装同一版 |

### 0001 做了什么

上游 0.4.7 已经支持多个 OpenAI-compatible 端点（`openaiCompatible.2` … `.99`），但**列表里只有 host 一行小字**，表单里只有 token 和 URL 两个输入框，没有任何地方能写"这是云雾还是老张的站"。

改完后的行为：

- **列表**：标题是你起的名字，host 仍在下面那一行；没起名的仍显示 `OpenAI-Compatible API`
- **搜索**：名字和 host 都能搜到
- **`…` 菜单**：多一项 `Rename`（只对 OpenAI-compatible 端点出现，其它 provider 不可能重复，改名只会让报 bug 时对不上号）
- **端点表单**：最上面多一格 `Name (Optional)`，紧挨在 token 和 URL 之前
- **聊天里的模型菜单**：按名字分组，没起名的回落到 host
- **登出确认框**：先说名字，再说 host

名字只存在本 App 的 `UserDefaults`（键 `provider.names`），**不进 keychain、不进凭证、不发给 apelin-agent 或 kwwk**。它是显示层的，丢了不影响任何登录状态。

新增文件 `Apelin/Interface/Settings/Accounts/ProviderLabel.swift`。工程用的是 `PBXFileSystemSynchronizedRootGroup`（objectVersion 77），新文件自动进 target，不需要改 `project.pbxproj`。

**全部字符串都用目录里已有的键**（`Name`、`Rename`、`Save`、`Cancel`、`%@ (Optional)`、`%@ Options`、`Sign Out of %@?`）。`build` 之后会跑 `check-catalog-keys.py`，任何一个编译器抽出来却不在 `Localizable.xcstrings` 里的字面量都会让它失败——所以没加新键。

## 待做

```
0003-balance.patch             # 余额胶囊 + 详情页
0004-session-search.patch      # 会话内搜索
0005-compaction-truncate.patch # 压缩前截断工具输出
```

`0005` 对应那个 `compaction left 120801 tokens, above the recovery target of 78643`。0.4.7 的 `NativeCompactionFallback` 只处理"压缩返回了空摘要"，不处理"压缩完还是太大"——那一条仍然是未修的。

## 生成方式

改完 `apelin-047/`（v0.4.7 的稀疏克隆）之后：

```bash
cd apelin-047
git add -N <新增文件>            # 不加这一句，新文件不会进 diff
git diff -- Apelin/Interface > ../apelin-plus/patches/0001-endpoint-names.patch
git diff -- Configuration/Version.xcconfig > ../apelin-plus/patches/0002-local-version.patch
```

**不要加 `-c core.autocrlf=false`。** 本机 `core.autocrlf=true`，绕过它会让 CRLF 工作区和 LF 索引的差异被算成全文件重写：393 行的补丁会变成 2565 行。

## 验证

把 `v0.4.7` 的原始文件抓下来，在干净目录里 `git apply` 一遍。当前三个补丁实测全部 `OK`：`IOS_SDK_TIER` 落到 26.5、版本落到 0.4.8、新文件到位、`ChatController` 的模型菜单按名字分组。
