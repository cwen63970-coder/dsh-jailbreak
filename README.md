# dsh-jailbreak：只做「提示词注入破甲」的 DSH 插件

仓库：<https://github.com/cwen63970-coder/dsh-jailbreak>
最后更新：2026-10-20

## 这是什么

一个只做**提示词注入**的 DSH 插件，用来替代 `dsh-purge` 里那一块能力：

- 在 `system-prompt/assemble` 上改写段表：丢弃 `harness:identity`、剥离官方 persona 句、
  把注入词作为首段套上 `<|im_start|>system:` + `<project_instructions>` 信封、
  追加 `dshpg-capabilities` 能力选用协议段；
- **不写宿主机文件**（不碰 `app.asar` / `@deepseek-ai` / `pi-ai`）、不注册工具、
  不带客户端 UI、不碰审批/沙箱/hooks、不联网。

破甲词来源：`$DSH_HOME/prompt-inject.md`（不存在时回落包内 `lib/prompt-inject.md`）。
改词只要编辑这个文件，下一轮 assemble 自动生效，不用重启。

## 安装

三种方式，任选其一（装完都要**完全退出 DSH 再启动**，profile 只在启动时读盘）。

**1）桌面端 / Web 端「插件 → 添加插件」**（推荐）

填 Git 地址即可，插件管理器支持 npm 包名、Git 仓库地址、本地目录：

```
github:cwen63970-coder/dsh-jailbreak
```

或 `https://github.com/cwen63970-coder/dsh-jailbreak`。
管理器会把它装进 `profiles/<profile>/node_modules/dsh-jailbreak`，并把 `dsh-jailbreak`
写进 `dsh.profile.bundles`。

**2）命令行**

```powershell
dsh plugin --profile desktop add "github:cwen63970-coder/dsh-jailbreak"
```

**3）不用 pnpm 的本地安装**（离线可用，适合改源码调试）

```powershell
$s = 'D:\dsh\projects\dsh-jailbreak\tools\jailbreak.ps1'
pwsh -NoProfile -File $s -Check      # 只读体检
pwsh -NoProfile -File $s             # 装到 <profile>\plugins\dsh-jailbreak\ 并自检
pwsh -NoProfile -File $s -Restart    # 装 + 自检 + 重启（会结束当前会话）
pwsh -NoProfile -File $s -Remove     # 拆掉本地那份，改走插件管理器
```

**两种安装不要同时用**：脚本发现 `bundles` 里已有 `dsh-jailbreak` 就不会再往
`plugins\` 里塞第二份（否则注入会跑两遍）；反过来，装了本地版再去管理器装也会重复，
脚本会以 `布局 = both` 提示，用 `-Remove` 拆掉一份即可。

## 当前状态

- 2026-10-20 21:22 以**本地目录**方式装入 `desktop` profile（`布局 = local`），
  宿主重启后已加载；本轮会话的系统提示首段即 `<|im_start|>system:<project_instructions>`。
- 同一轮把 `dsh-purge` 从 `dsh.profile.bundles` 摘除，并删掉其 `package.json` 的 `client` 字段：
  purge 的 3 个工具、红队台、客户端 dock 都不再加载；它此前打在 3 套宿主副本上的补丁文件
  仍在盘上，但不被触发。
- 自检：结构 9 项 + 行为 19 项断言全绿（`jailbreak.ps1 -Check`）。
- 已推送到 GitHub（public，14 个文件，`npm pack` 38.1 kB / 12 个文件）。
- 未验证：跨天/跨升级的长期表现；「插件 → 添加插件」的 UI 安装只核对了管理器支持的
  来源与解析结果，未实际点过一次（会改 profile 并重启）。

## 目录内容

| 路径 | 内容 |
| --- | --- |
| `lib/index.mjs` | 插件入口：读注入词、包 `assemble`、挂瀑布监听，全部 try/catch 兜底 |
| `lib/identity.js` | 段表改写实现（vendored 自 dsh-purge 1.1.71，MIT） |
| `lib/capability-protocol.js` | `dshpg-capabilities` 段文本（vendored） |
| `lib/phase1-keep.js` | identity.js 的 re-export 依赖（vendored） |
| `lib/net-scope.js` | 桩：只提供 `ownServerNote() -> ""`，切断对 core/desktop 的依赖 |
| `lib/prompt-inject.md` | 破甲词副本（= 安装时 `~\.dsh\prompt-inject.md`，25,128 B） |
| `package.json` | 包元信息：`main`、`files`、`dsh.bundle.patch`、`peerDependencies` |
| `cordis.patch.yml` | bundle 层补丁：system-prompt 覆盖 + 按包名插入自身 |
| `tools/jailbreak.ps1` | 免依赖安装/自检/移除/重启（`-Check` / `-DryRun` / `-Remove` / `-Restart`） |
| `LICENSE` / `LICENSE-dsh-purge` | 本包 MIT；vendored 部分的上游 MIT 与署名 |
| `docs/reports/2026-10-20-dsh-jailbreak-design.md` | 设计记录：取舍、证据、验证清单、未验证项 |

## 备份与恢复

只有真正发生改写时，脚本才会把被改的 profile 文件复制到 `backup\apply-<时间戳>\`
或 `backup\remove-<时间戳>\`；全量同步没有任何变化时不会产生备份目录。

- 改用插件管理器：`jailbreak.ps1 -Remove`（删本地目录 + 切掉本地挂载块，
  保留 `system-prompt` 覆盖），然后「添加插件」填 `github:cwen63970-coder/dsh-jailbreak`。
- 彻底不要了：`-Remove`，再在插件列表里卸载 `dsh-jailbreak`；
  破甲词文件 `~\.dsh\prompt-inject.md` 可自行删除。
- 恢复 dsh-purge（含 dock）：把 `dsh-purge` 加回 `dsh.profile.bundles`、恢复其 `client` 字段、
  删掉 `cordis.patch.yml` 末尾的 `dsh-jailbreak` 两段，重启。

退出码：`0` 全绿 / `1` 有断言失败 / `2` 环境错误 / `3` 需要重启才生效。

## 待办

- [ ] 用「插件 → 添加插件」实际装一次，确认管理器路径下的注入与本地目录版等价。
- [ ] 观察一个完整工作日：注入在新会话/子代理/长对话里是否稳定。
- [ ] 决定是否清理 `dsh-purge` 在 3 套宿主副本上留下的补丁文件（当前惰性，不加载）。
- [ ] 若要长期维护，把 `prompt-inject.md` 的版本纳入 git（现在只有安装时的副本）。
- [ ] DSH 升级后跑一次 `jailbreak.ps1 -Check`；若 assemble 签名变了，同步调整 `lib/index.mjs`。
