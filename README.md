# dsh-jailbreak：只做「提示词注入破甲」的 DSH 插件

最后更新：2026-10-20

## 这是什么

一个只做**提示词注入**的 DSH profile 插件，用来替代 `dsh-purge` 里那一块能力：

- 在 `system-prompt/assemble` 上改写段表：丢弃 `harness:identity`、剥离官方 persona 句、
  把注入词作为首段套上 `<|im_start|>system:` + `<project_instructions>` 信封、
  追加 `dshpg-capabilities` 能力选用协议段；
- **不写宿主机文件**（不碰 `app.asar` / `@deepseek-ai` / `pi-ai`）、不注册工具、
  不带客户端 UI、不碰审批/沙箱/hooks、不联网。

破甲词来源：`$DSH_HOME\prompt-inject.md`（不存在时回落插件目录自带副本）。
改词只要编辑这个文件，下一轮 assemble 自动生效，不用重启。

插件是**单入口 + 3 个本地模块**，放在 profile 的 `plugins\dsh-jailbreak\`，
不参与 pnpm 依赖图（所以不会因为 `pnpm install` 被覆盖）。

## 当前状态

- 2026-10-20 21:22 装入 `desktop` profile，宿主重启后已加载；
  本轮会话的系统提示出现 `<|im_start|>system:<project_instructions>` 信封，注入生效。
- `dsh-purge` 已从 `dsh.profile.bundles` 摘除，并删掉其 `package.json` 的 `client` 字段：
  - purge 的 3 个工具、红队台、客户端 dock（右上浮动面板 + `dsh-purge` 页签）都不再加载；
  - purge 之前打在 3 套宿主副本上的补丁文件仍在盘上，但因不在 bundles 里、也不会被触发，处于惰性状态。
- 离线自检：`tools\jailbreak.ps1 -Check` 结构 9 项 + 行为 19 项断言全绿
  （含"插件文件早于宿主启动 = 已加载"这条判据）。
- 未验证：跨天/跨升级的长期表现；DSH 升级后 profile 层是否仍然生效；`-Restart` 的杀进程/拉起分支
  只做过逻辑审查，未实跑（跑一次就意味着当前会话中断）。

## 目录内容

| 路径 | 内容 |
| --- | --- |
| `src\index.mjs` | 插件入口：读注入词、包 `assemble`、挂瀑布监听，全部 try/catch 兜底 |
| `src\identity.js` | 段表改写实现（vendored 自 dsh-purge 1.1.71，MIT） |
| `src\capability-protocol.js` | `dshpg-capabilities` 段文本（vendored） |
| `src\phase1-keep.js` | identity.js 的 re-export 依赖（vendored） |
| `src\net-scope.js` | 桩：只提供 `ownServerNote() -> ""`，切断对 core/desktop 的依赖 |
| `src\prompt-inject.md` | 破甲词副本（= 安装时 `~\.dsh\prompt-inject.md`，25,128 B） |
| `src\package.json` | 仅声明 `type: module`，让目录内 `.js` 按 ESM 解析 |
| `tools\jailbreak.ps1` | 唯一入口：同步 + 自检（结构 9 项 + 行为 19 项断言）；`-Check` 只读、`-DryRun` 预览、`-Restart` 重启 |
| `LICENSE-dsh-purge` | 上游 MIT 许可与署名 |
| `docs\reports\2026-10-20-dsh-jailbreak-design.md` | 设计记录：取舍、证据、验证清单、未验证项 |

## 备份与恢复

只有真正发生改写时，脚本才会把被改的 profile 文件复制到 `backup\apply-<时间戳>\`
（文件名 `cordis.patch.yml` / `package.json` / `dsh-purge-package.json`）；
全量同步跑下来没有任何变化时，不会产生备份目录。

一键操作（只有这一个脚本）：

```powershell
$s = 'D:\dsh\projects\dsh-jailbreak\tools\jailbreak.ps1'
pwsh -NoProfile -File $s -Check      # 只读体检
pwsh -NoProfile -File $s             # 同步 + 自检（默认不重启）
pwsh -NoProfile -File $s -DryRun     # 只看同步计划
pwsh -NoProfile -File $s -Restart    # 同步 + 自检 + 重启（会结束当前会话）
```

退出码：`0` 全绿 / `1` 有断言失败 / `2` 环境错误 / `3` 需要重启才生效。

恢复旧状态（没有回滚脚本，直接改回三处即可，改前先从 `backup\apply-*` 备份目录拷回）：

1. `cordis.patch.yml` 删掉末尾两段（`# --- dsh-jailbreak:` 开头到文件末尾）；
2. `package.json` 的 `dsh.profile.bundles` 里加回 `"dsh-purge"`；
3. `node_modules\dsh-purge\package.json` 的 `dsh` 下加回 `client` 字段（platform `web` +
   5 个 `@deepseek-ai/dsh-client-*`），然后重启桌面端。

`dsh-purge` 的依赖行一直在 `dependencies` 里（故意保留，避免动 pnpm 锁文件）。

## 待办

- [ ] 观察一个完整工作日：确认注入在新会话/子代理/长对话里都稳定，日志无 `rewrite.failed`。
- [ ] 决定是否清理 `dsh-purge` 在 3 套宿主副本上留下的补丁文件（`resources\app\dsh\node_modules`、
      `profiles\node_modules`、`D:\deepseek-harness`，共 100+ 文件 + 56 个 `.dshpurge.bak`）。
      它们现在不生效，但会让"这个包到底改了宿主什么"难以判断。
- [ ] 若要长期维护，把 `prompt-inject.md` 纳入版本管理（现在只有安装时的副本）。
- [ ] DSH 升级后跑一次 `jailbreak.ps1 -Check`；升级若改了 assemble 签名，需要按新形状调整 `index.mjs`。
