# 在没有 Mac 的机器上编译 ApelinPlus

你的机器没有 Swift 工具链，所以编译放到 GitHub 的 macOS runner 上跑。你要做的只有三件事：**建个空仓库、拿一个 token、跑一条命令**。剩下的是 CI 的事。

全程约 5 分钟，其中 2 分钟在等 CI。

---

## 第 1 步：建一个空仓库（30 秒）

打开 <https://github.com/new>

| 字段 | 填什么 |
|---|---|
| Repository name | `ApelinPlus` |
| Description | 随便，或者留空 |
| Public / Private | **选 Public** —— 公开仓库的 macOS runner 不烧额度，私有仓库 2000 分钟/月额度除以 10 倍计费只剩 200 分钟 |
| Add a README file | **不要勾** |
| Add .gitignore | **不要勾** |
| Choose a license | **不要勾** |

→ `Create repository`

建完停在这一页，**什么都别点**（尤其别点 "uploading an existing file"，会多出一个 commit 让后面 push 冲突）。

---

## 第 2 步：拿 token

两种 token，选一种。区别只有一处：**fine-grained 建不了仓库，classic 能**。

### 路线 A：fine-grained（推荐，权限最小）

打开 <https://github.com/settings/personal-access-tokens/new>

| 字段 | 填什么 |
|---|---|
| Token name | `apelinplus-ci` |
| Expiration | 30 days（够用了，过期再生成） |
| Resource owner | 你的账号 |
| Repository access | **Only select repositories** → 选中刚建的 `ApelinPlus` |

往下滚到 **Permissions** → **Repository permissions**，只勾这三项：

| 权限 | 设成 | 为什么 |
|---|---|---|
| **Contents** | Read and write | 推代码 |
| **Workflows** | Read and write | **推 `.github/workflows/` 必须有它**，缺了会被拒 |
| **Actions** | Read and write | 可选。想用命令行看 CI 日志/重跑才需要 |

`Metadata` 会自动变成 Read-only，不用管。其他全留 No access。

→ `Generate token` → 复制那串 `github_pat_xxxxxxxx`

> ⚠️ **这个 token 只显示一次。** 关掉页面就再也看不到，只能重新生成。

### 路线 B：classic（省一步，权限大）

打开 <https://github.com/settings/tokens/new>

| 字段 | 填什么 |
|---|---|
| Note | `apelinplus-ci` |
| Expiration | 30 days |
| Select scopes | 勾 **`repo`**（整个方块，子项会自动全选）+ 勾 **`workflow`** |

→ `Generate token` → 复制 `ghp_xxxxxxxx`

classic token 能调 `POST /user/repos`，所以脚本可以连仓库一起给你建好，第 1 步都能省。

---

## 第 3 步：推

### Windows（PowerShell）

```powershell
cd C:\Users\Administrator\WorkBuddy\2026-11-16-16-47-22\work\apelin-plus

# 路线 A（仓库已手工建好）
.\provision.ps1 -Token "github_pat_xxxxxxxx" -SkipCreate

# 路线 B（classic token，连仓库一起建）
.\provision.ps1 -Token "ghp_xxxxxxxx"
```

第一次跑 PowerShell 可能拦脚本执行：

```
无法加载文件 provision.ps1，因为在此系统上禁止运行脚本
```

一次性放行：

```powershell
powershell -ExecutionPolicy Bypass -File .\provision.ps1 -Token "ghp_xxxxxxxx" -SkipCreate
```

### macOS / Linux / Git Bash

```bash
cd apelin-plus

# 路线 A
SKIP_CREATE=1 ./provision.sh github_pat_xxxxxxxx

# 路线 B
./provision.sh ghp_xxxxxxxx
```

---

## 第 4 步：看结果

脚本最后会打出一个链接：

```
https://github.com/<你>/ApelinPlus/actions
```

点进去，有三个 job 在跑：

| job | 看什么 |
|---|---|
| **swift test (macOS 15 / Swift 6)** | **这个绿了就等于代码可用。** |
| compile for iOS device (arm64) | 绿了才能往 Apelin 里塞 |
| strict concurrency warnings | 不阻塞，参考用 |

大概 2–3 分钟。

- **绿** → 告诉我，我接着做 UI 层和实例编辑表单
- **红** → 点那个红的 job → 右上角齿轮 → `Download log archive`，或者直接把红色那段展开复制，整段贴给我。**别只贴最后一行**，Swift 的编译错误第一行才是根因

---

## 第 5 步：顺手试一下能不能出 .deb

推上去之后，仓库的 **Actions** 页面里有两个 workflow：

| workflow | 触发 | 干什么 |
|---|---|---|
| **CI** | 自动（push 就跑） | 验证 ApelinPlus 这个包能编译、测试能过 |
| **Apelin .deb (upstream)** | **手动点** | clone 上游 Apelin 原版，在 macOS runner 上编出可安装的 .deb |

第二个现在还是空的（`patches/` 里没东西），但它能回答一个你现在没法回答的问题：**这台云端机器能不能把 Apelin 编出来**。

试一下：

1. Actions → 左侧选 `Apelin .deb (upstream)` → 右边 `Run workflow`
2. `flavor` 保持 `roothide`（除非你用的是 rootless 越狱）
3. `ref` 保持 `main`
4. 点绿色的 `Run workflow`

跑完 10–20 分钟，成功的话 job 页面底部有 **Artifacts** → `apelin-roothide-1.zip`，里面就是 .deb。

**这一步大概率会红。** 红在哪、为什么红，比红本身有用：

| 红在 | 说明 | 我怎么办 |
|---|---|---|
| `sdk-tier` / `exit 69` | runner 的 Xcode 不够新（Apelin 要求 iOS 27.1 SDK，即 Xcode 27） | 把 `runs-on` 改成 `xcode-27`，或者等镜像跟进 |
| `ldid is required` | Homebrew 的 ldid 装不上 | 换从源码编，或者用 `ldid` 的 Procursus 源 |
| `dpkg-deb is required` | 同上 | `brew install dpkg` 应该够，不行就改 workflow 里装 |
| 编到一半 Swift 报错 | 上游 main 本身是坏的 | 换 `ref` 成上一个 tag 再试 |
| 签名/打包阶段 | `Scripts/package-deb.sh` 依赖某个环境变量 | 看脚本，补到 workflow 的 env 里 |

把红色那段日志给我，我改 workflow。**这条路一旦通，你以后每次功能改动都能在手机上直接装来试，完全不需要 Mac。**

---

## 报错对照表

| 你看到的 | 真正的原因 | 怎么修 |
|---|---|---|
| `refusing to allow a Personal Access Token to create or update workflow ... without 'workflow' scope` | token 缺 `Workflows` 权限 | 回第 2 步把 Workflows 改成 Read and write，或 classic 勾 `workflow` |
| `403` 或 `404` + `Resource not accessible by personal access token` | fine-grained token 调了建仓库接口 | 加 `-SkipCreate`，仓库去网页手工建 |
| `remote: Repository not found` | 仓库名或 owner 拼错，或 token 没勾那个仓库 | 检查 `Repository access` 有没有选中 ApelinPlus |
| `failed to push some refs ... fetch first` | 建仓库时手滑勾了 README | 删掉仓库重建（别勾任何东西），或先 `git pull --rebase` |
| `找不到 git` | PATH 里没有 | `winget install --id Git.Git -e`。脚本也会自动去 `~/.workbuddy/binaries/PortableGit` 找一份 |
| CI 里 `error: unable to find utility "swift"` | 一般不会，macos-15 自带 | 换 `macos-14` 加一步 `xcode-select` 选 Xcode 16 |
| CI 卡在 `Waiting for a runner` 很久 | 私有仓库 + macOS runner 排队 | 把仓库改成 Public（Settings → 最底下 Change visibility） |

---

## 不想搞 token 的两条路

**① 把 token 贴给我，我这边直接推。**
我有 git 和网络，你把 token 发过来，我建仓库、推代码、盯 CI，红了就地改。你什么都不用装。用完记得去 GitHub 吊销。

**② 用 GitHub CLI（如果你已经装了）**

```powershell
winget install --id GitHub.cli -e
gh auth login          # 走浏览器，不用手工搞 token
cd C:\Users\Administrator\WorkBuddy\2026-11-16-16-47-22\work\apelin-plus
gh repo create ApelinPlus --public --source=. --remote=origin --push
```

`gh` 自己处理权限，`workflow` scope 也在它要的授权范围里，不会有那个坑。

---

## 关于费用

| 仓库类型 | macOS runner | 这个包跑一轮 |
|---|---|---|
| Public | 免费无限量 | 约 2–3 分钟 |
| Private | 2000 分钟/月，macOS 按 **10 倍**计费 → 实际 200 分钟 | 约 2–3 分钟（折算 20–30 额度） |

私有仓库大约能跑 70 次。够用了，但公开更省心。

---

## 推上去之后我会做什么

CI 绿了之后，下一批代码的顺序是：

1. **实例编辑表单**（SwiftUI）—— 标签、配色、分组、置顶、余额开关
2. **服务商列表重写** —— 用 `ProviderInstance` 替换现在按 `provider.rawValue` 去重的那套
3. **余额详情页** —— 大数字 + 7 日柱图 + 接口透明度
4. **会话内搜索**
5. **上下文压缩失败的修复**（这个不在这条线上，要动 agent 侧）

其中第 2 步会碰 keychain 的键格式，是唯一有存量数据风险的一步。我会做成"老账号自动成为实例 1"，不需要你手动迁移。
