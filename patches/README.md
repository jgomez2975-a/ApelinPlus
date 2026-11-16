# patches/

`apelin-deb.yml` 在 clone 上游之后，会把这里的每个 `*.patch` 依次 `git apply --3way`。

## 为什么用 patch 而不是 fork

fork 一份 2421 个文件的仓库，上游一更新就得 rebase，而且我改的每个文件都在 diff 里糊成一团。patch 是**只记录我改了什么**，上游怎么变都不影响 patch 本身的语义，冲突了 `--3way` 会明确告诉你哪一行对不上。

## 目录约定

```
patches/
├─ 0001-provider-instance.patch      # 实例模型接进 AccountDesk
├─ 0002-balance-ui.patch             # 余额胶囊 + 详情页
├─ 0003-session-search.patch         # 会话内搜索
└─ 0004-compaction-truncate.patch    # 压缩前截断工具输出
```

编号是应用顺序，不要乱。每个 patch 只做一件事，失败了能一眼看出是哪个功能挂了。

## 生成方式

改完 `upstream/` 里的代码之后：

```bash
cd upstream
git add -A
git diff --cached > ../patches/0001-provider-instance.patch
```

或者分文件：

```bash
git diff -- Apelin/Interface/Settings/Accounts/ > ../patches/0002-balance-ui.patch
```

## 当前状态

**空。** 现在推上去只能构建原版 Apelin，验证的是"CI 这条路通不通"，不是"功能有没有生效"。

等 `ci.yml` 绿了、确认 ApelinPlus 能编译之后，第一批 patch 才会出现在这里。
