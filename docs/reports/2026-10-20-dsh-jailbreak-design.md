# dsh-jailbreak 设计记录

最后更新：2026-10-20

## 1. 目标

只保留 `dsh-purge` 的"提示词注入破甲"，其余（宿主补丁、客户端 dock、红队台、审批/沙箱改造）
一律不要。交付形态是一个能长期留在 `desktop` profile 里的独立插件。

## 2. 为什么不裁剪 dsh-purge

`lib/index.js` 顶部有 14 条静态 import（`core` / `host` / `skills` / `update` / `reapply` /
`official-update` / `redteam/role-section` / `rewind` / `continue-retry` / `uninstall` /
`drill-grant` / `net-scope` / `extract-asar` / `settle-policy`），而 `core.js` 又依赖
`desktop.js`、`hooks-deny.js`、`table-read.js`、`surface.js`、`host-clean.js`、`phase1-keep.js`；
`identity.js` 依赖 `net-scope.js`，`net-scope.js` 反过来依赖 `core.js`。

也就是说：想删掉补丁机制，必须同时改 `index.js` 的 import 与 3 处 `ctx.tools.register`，
再切断 `identity → net-scope → core → desktop` 链。与其在 108 KB 的入口上做手术，
不如保留收益最高的两个现成模块，自己写 150 行入口。

## 3. 设计

```
plugins\dsh-jailbreak\
  index.mjs              入口：读词 → installAssembleGuard → 瀑布兜底
  identity.js            vendored（段表改写：剥身份、信封、折叠、能力段）
  capability-protocol.js vendored（dshpg-capabilities 文本）
  phase1-keep.js         vendored（identity 的 re-export 依赖）
  net-scope.js           桩：ownServerNote() -> ""
  prompt-inject.md       破甲词副本（回落用）
  package.json           只声明 type: module
```

三条关键取舍：

1. **入口自写，模块 vendor**。`identity.js` 是被 1.1.71 反复修过的段表改写器（ChatML 信封、
   字面 cwd、`escapeDshInterpolation`、`literalSectionFallback`），重写等于重踩一遍坑；
   而 `core.js` 那套补丁/解包/换 asar 机制与目标无关，直接不引入。
2. **失败即降级**。`installAssembleGuard` 内部对 rewrite 抛错会原样返回宿主装配结果；
   入口里再加一层 try/catch。坏掉的后果是"没有注入"，不是"宿主起不来 / 提示词被丢光"。
3. **注入词外置**。`$DSH_HOME\prompt-inject.md` 按 mtime 缓存，改完下一轮生效；
   文件缺失时回落插件目录副本，两者都没有时只做剥离、不塞信封。

## 4. profile 层改动（3 处，均可逆）

| 文件 | 改动 |
| --- | --- |
| `profiles\desktop\cordis.patch.yml` | 追加 `- id: system-prompt` 覆盖（`includeHarnessIdentity:false`、persona 前后缀置空）+ `- insert:` 挂载 `./plugins/dsh-jailbreak/index.mjs` |
| `profiles\desktop\package.json` | `dsh.profile.bundles` 摘掉 `dsh-purge`（`dependencies` 保留，不动锁文件） |
| `...\node_modules\dsh-purge\package.json` | 删除 `dsh.client` 字段（客户端 dock 不再加载） |

## 5. 验证

| 项 | 方法 | 结果 |
| --- | --- | --- |
| 段表改写逻辑 | `tools\jailbreak.ps1` 内置的行为自检（假 ctx 走 apply → assemble） | 19 项断言全 PASS |
| 安装态 | 同脚本的结构检查 | 9 项全 PASS |
| 幂等 | 默认模式重跑 | 全部"不变/已存在"，零写入、不产生备份目录 |
| 预览安全 | `-DryRun` / `-Check` | 未改任何文件、未结束进程 |
| 真实生效 | 宿主 21:22:47 重启后的本轮系统提示 | 首段为 `<|im_start|>system:` + `<project_instructions>`，`harness:identity` 不存在 |

"插件文件早于宿主启动"这一项是关键判据：文件比进程新，就说明改动还没被加载，
脚本会以退出码 3 提示需要重启。

## 6. 边界与风险

- 只在 `desktop` profile 生效；`web` / `headless` profile 没有这条挂载。
- 注入词为空时会退化为"只剥官方身份 + 只加能力段"，不会报错，但也没有破甲效果。
- `dsh-purge` 之前的 100+ 个宿主补丁文件仍在盘上（3 套副本），只是不再被加载；
  它们会干扰"这个包到底改了宿主什么"的判断，清理需单独立项。
- DSH 若改变 `systemPrompt.assemble` 的入参/返回形状，需要同步调整 `index.mjs`；
  `identity.js` 本身是按 `{ sections: [{ name, text, order }] }` 写的。

## 7. 未验证

- 跨天运行、子代理会话、长对话里的稳定性（只看了一轮会话）。
- DSH 升级后 profile 层补丁与 `plugins\` 相对路径是否继续被识别。
- 极端情况：注入词里带未知 `{{variable}}` 时，`escapeDshInterpolation` 的兜底是否覆盖全部宿主版本。
