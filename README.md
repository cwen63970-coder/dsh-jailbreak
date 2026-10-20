# dsh-jailbreak

给 DeepSeek Harness（DSH）用的**提示词注入**插件：只改写系统提示词的装配结果，
不碰宿主文件、不注册工具、不带界面、不改审批与沙箱。

```
组装前：harness:identity + persona + 一堆官方禁令
组装后：<|im_start|>system:<project_instructions> … </project_instructions> + 能力选用协议 + 官方工具说明
```

## 它做什么

1. 丢掉 `harness:identity` 段，并剥离官方 persona 句；
2. 把 `$DSH_HOME/prompt-inject.md` 放进首段，套上 `<project_instructions>` 信封；
3. 追加 `dshpg-capabilities` 段，让模型先读 skill / MCP 目录再动手。

只挂在 `system-prompt/assemble` 上，全部改写都在内存里完成。插件抛错时原样返回宿主装配结果，
最坏情况是"没有注入"，不会把提示词装配弄挂。

## 安装

三种方式任选其一，装完都要**完全退出 DSH 再启动**（profile 只在启动时读盘）。

**插件管理器**（桌面端 / Web 端「插件 → 添加插件」）

```
https://github.com/cwen63970-coder/dsh-jailbreak.git
```

**命令行**

```powershell
# 桌面端
dsh plugin --profile desktop add "https://github.com/cwen63970-coder/dsh-jailbreak.git"

# Web 端
dsh plugin --profile web add "https://github.com/cwen63970-coder/dsh-jailbreak.git"
```

`--profile` 填实际的 profile 名（`desktop` / `web`）；管理器会把包放进 `profiles/<profile>/node_modules/dsh-jailbreak`，
并把 `dsh-jailbreak` 写进该 profile 的 `dsh.profile.bundles`。只 `pnpm add` 不进 bundles 的话不会加载。

**不用 pnpm 的本地安装**

```powershell
$s = 'tools\jailbreak.ps1'
pwsh -NoProfile -File $s -Check              # 只读体检
pwsh -NoProfile -File $s                     # 装到 <profile>\plugins\dsh-jailbreak\
pwsh -NoProfile -File $s -Restart            # 装 + 重启（会结束当前会话）
pwsh -NoProfile -File $s -Remove             # 拆掉本地那份，改走管理器
```

脚本会识别四种布局（`local` / `package` / `both` / `none`）；发现两种安装同时存在会提示，
避免同一套注入跑两遍。

## 配置

`cordis.patch.yml` 里的默认值，可在 profile 层覆盖：

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `enabled` | `true` | 关掉后完全不动段表 |
| `file` | `''` | 破甲词路径；空 = `$DSH_HOME/prompt-inject.md` |
| `stripMnemon` | `true` | 丢弃宿主 mnemon 段 |
| `dropWorkspaceBaseline` | `true` | 有注入词时丢弃官方 workspace baseline |
| `capabilityProtocol` | `true` | 追加能力选用协议段 |
| `verbose` | `false` | 打开后每次 assemble 往控制台写一行 |

## 破甲词

放在 `$DSH_HOME/prompt-inject.md`（Windows 一般是 `C:\Users\<你>\.dsh\prompt-inject.md`）。
文件按 mtime 缓存，改完下一轮对话自动生效，不用重启。文件不存在时回落到包内
`lib/prompt-inject.md`。

## 兼容性

- 面向 DSH `0.2.1-rc.2`；`dshTarget` 字段同此。
- 依赖宿主提供的 `systemPrompt.assemble` 与 `system-prompt/assemble` 事件；宿主改签名时需要同步调整
  `lib/index.mjs`。
- 若宿主某版本重新注册了 `cwd` 变量，插件里的注册会被跳过，不会重复。

## 与 dsh-purge 的关系

`lib/identity.js`、`lib/capability-protocol.js`、`lib/phase1-keep.js` 来自
[dsh-purge](https://github.com/YuJunZhiXue/dsh-purge) 1.1.71（MIT，作者小杨；DSH 0.2.1 适配部分
由 Star / Potato1008ypy 完成）。本仓库只保留其中的段表改写实现，宿主补丁、红队台、客户端 dock
都没有带过来。见 `LICENSE` 与 `LICENSE-dsh-purge`。

## 排查

- **没生效**：确认该 profile 的 `dsh.profile.bundles` 里有 `dsh-jailbreak`，并已重启。
- **注入跑了两遍**：同时装了 `plugins\dsh-jailbreak` 与管理器包，用 `-Remove` 拆掉一份。
- **注入词没更新**：确认改的是 `$DSH_HOME/prompt-inject.md`，不是包内副本。
