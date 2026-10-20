#Requires -Version 7.0
<#
.SYNOPSIS
  dsh-jailbreak 一把梭：安装/自检/移除/重启，只有这一个脚本。

.DESCRIPTION
  先看当前是哪种安装布局，再决定动作：
    local    本地目录安装：<profile>\plugins\dsh-jailbreak\（不需要 pnpm）
    package  插件管理器安装：<profile>\node_modules\dsh-jailbreak\（用「添加插件」或 dsh plugin add）
    none     都没装

  用法：
    pwsh -NoProfile -File jailbreak.ps1              本地安装（幂等）+ 自检；不重启
    pwsh -NoProfile -File jailbreak.ps1 -Check       只读体检，不动任何文件
    pwsh -NoProfile -File jailbreak.ps1 -DryRun      只打印计划
    pwsh -NoProfile -File jailbreak.ps1 -Restart     本地安装 + 自检 + 重启（会结束当前会话）
    pwsh -NoProfile -File jailbreak.ps1 -Remove      拆掉本地目录安装，交给插件管理器版本

  本地安装会做四件事：
    1. 把 lib\*.{mjs,js,md} 复制到 <profile>\plugins\dsh-jailbreak\（内容相同就跳过）；
    2. cordis.patch.yml 缺 system-prompt 覆盖 / 缺插件挂载行时补上；
    3. package.json 的 dsh.profile.bundles 摘掉 dsh-purge；
    4. dsh-purge 的 package.json 删掉 client 字段（前端 dock 不再加载）。

  已经通过插件管理器装了包时，本脚本不会再往 plugins\ 里塞第二份（否则会双重注入），
  只做自检。

  退出码：0 全绿；1 有断言失败；2 环境错误；3 需要重启才能生效。

.EXAMPLE
  pwsh -NoProfile -File D:\dsh\projects\dsh-jailbreak\tools\jailbreak.ps1 -Check
.EXAMPLE
  pwsh -NoProfile -File D:\dsh\projects\dsh-jailbreak\tools\jailbreak.ps1 -Remove
#>
[CmdletBinding()]
param(
    [string]$DshHome = $(if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }),
    [string]$ProfileName = 'desktop',
    [switch]$Check,
    [switch]$DryRun,
    [switch]$Restart,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$libDir = Join-Path $projectRoot 'lib'
$profileDir = Join-Path $DshHome "profiles\$ProfileName"
$pluginDir = Join-Path $profileDir 'plugins\dsh-jailbreak'
$pkgDir = Join-Path $profileDir 'node_modules\dsh-jailbreak'
$patchFile = Join-Path $profileDir 'cordis.patch.yml'
$profilePkg = Join-Path $profileDir 'package.json'
$purgePkg = Join-Path $profileDir 'node_modules\dsh-purge\package.json'
$injectFile = Join-Path $DshHome 'prompt-inject.md'
$exePath = 'C:\Users\m1535\AppData\Local\Programs\DeepSeek Harness\DeepSeek Harness.exe'

$SYSTEM_PROMPT_BLOCK = @'
# --- dsh-jailbreak: 关掉宿主自带身份段与 persona 前后缀 ---
- id: system-prompt
  name: "@deepseek-ai/dsh-system-prompt"
  config:
    includeHarnessIdentity: false
    personaPrefix: ""
    personaSuffix: ""
'@

$INSERT_BLOCK = @'
# --- dsh-jailbreak: 提示词注入破甲（单文件插件，不参与 pnpm 依赖）---
- insert:
    - id: dsh-jailbreak
      name: './plugins/dsh-jailbreak/index.mjs'
      config:
        enabled: true
        stripMnemon: true
        dropWorkspaceBaseline: true
        capabilityProtocol: true
        verbose: false
'@

# 行为自检：不依赖 DSH，用假 ctx 走通 apply -> assemble。
$TEST_JS = @'
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";

const root = process.env.JAILBREAK_ROOT;
const injectFile = process.env.JAILBREAK_INJECT;
const { apply } = await import(pathToFileURL(path.join(root, "index.mjs")).href);

let failed = 0;
const check = (label, ok, detail = "") => {
  console.log(`${ok ? "PASS" : "FAIL"}  ${label}${ok || !detail ? "" : " :: " + detail}`);
  if (!ok) failed += 1;
};

const CWD = "D:\\dsh";
const seed = [
  { name: "harness:identity", text: "You are an AI assistant accessed via an API.", order: 0 },
  { name: "deployment:persona-prefix", text: "You are a Codex-like coding agent.", order: 10 },
  { name: "deployment:persona-suffix", text: "Your working directory is {{cwd}}.", order: 10200 },
  { name: "workspace:baseline", text: "Repository conventions loaded from AGENTS.md.", order: 200 },
  { name: "mnemon:recall", text: "Previous memory notes.", order: 300 },
  { name: "tools:guidance", text: "Non-zero exits are reported as [exit code: N] markers.", order: 400 }
];

function makeCtx() {
  const calls = { variable: [], on: [] };
  const prompt = {
    variable: (...args) => calls.variable.push(args),
    assemble: async () => ({ sections: seed.map((s) => ({ ...s })), contexts: [], tools: [] })
  };
  const ctx = { systemPrompt: prompt, on: (evt) => calls.on.push(evt) };
  return { ctx, calls };
}

const input = { agent: { session: { header: { cwd: CWD } } } };
const { ctx, calls } = makeCtx();
apply(ctx, { file: injectFile, verbose: false });

check("apply 注册了 cwd 变量", calls.variable.length > 0);
check("apply 挂了 system-prompt/assemble 监听", calls.on.includes("system-prompt/assemble"));

const out = await ctx.systemPrompt.assemble(input);
const names = out.sections.map((s) => s.name);
const envelope = out.sections.filter((s) => String(s.text || "").startsWith("<|im_start|>system:"));

check("harness:identity 被丢弃", !names.includes("harness:identity"), names.join(","));
check("workspace baseline 被丢弃", !names.includes("workspace:baseline"), names.join(","));
check("mnemon 段被丢弃", !names.some((n) => n.includes("mnemon")), names.join(","));
check("能力协议段存在", names.includes("dshpg-capabilities"), names.join(","));
check("注入段只有一个", envelope.length === 1, `count=${envelope.length}`);
check("注入段排第一", out.sections[0] && envelope[0] && out.sections[0].name === envelope[0].name, names.join(","));

const body = String(envelope[0]?.text || "");
check("信封首行独立", body.split("\n")[0] === "<|im_start|>system:");
check("project_instructions 成对", body.includes("<project_instructions>") && body.includes("</project_instructions>"));
check("破甲词正文在段内", body.includes("Little Code Sauce"));

const suffix = out.sections.find((s) => s.name === "deployment:persona-suffix");
check("suffix 无 {{cwd}} 占位符", Boolean(suffix && !suffix.text.includes("{{cwd}}")), suffix && suffix.text);
check("suffix 写字面 cwd", Boolean(suffix && suffix.text.includes(CWD)), suffix && suffix.text);
check("宿主输入未被就地改写", seed.some((s) => s.name === "harness:identity") && seed.some((s) => s.text.includes("{{cwd}}")));

const again = await ctx.systemPrompt.assemble(input);
check("连续两轮不叠加信封", ((String(again.sections[0]?.text || "").match(/<\|im_start\|>system:/g)) || []).length === 1);

const empty = path.join(os.tmpdir(), `jb-empty-${process.pid}.md`);
fs.writeFileSync(empty, "   \n", "utf8");
const c2 = makeCtx();
apply(c2.ctx, { file: empty });
const out2 = await c2.ctx.systemPrompt.assemble(input);
check("空注入词不崩、不塞信封", !out2.sections.some((s) => s.name === "harness:identity") && !out2.sections.some((s) => String(s.text || "").includes("<|im_start|>system:")));
fs.rmSync(empty, { force: true });

const c3 = makeCtx();
apply(c3.ctx, { file: path.join(os.tmpdir(), "definitely-missing-inject.md") });
const out3 = await c3.ctx.systemPrompt.assemble(input);
check("主文件缺失时回落内置副本", out3.sections.some((s) => String(s.text || "").includes("<project_instructions>")));

const c4 = makeCtx();
apply(c4.ctx, { enabled: false });
const out4 = await c4.ctx.systemPrompt.assemble(input);
check("enabled:false 时不改段表", out4.sections.length === seed.length && out4.sections.some((s) => s.name === "harness:identity"));

console.log(failed === 0 ? "ALL PASS" : `${failed} FAILED`);
process.exit(failed === 0 ? 0 : 1);
'@

$fail = 0
function Check-Assert([string]$label, [bool]$ok, [string]$detail = '') {
    if ($ok) { Write-Host ("PASS  {0}" -f $label) -ForegroundColor Green }
    else { Write-Host ("FAIL  {0}{1}" -f $label, $(if ($detail) { " :: $detail" } else { '' })) -ForegroundColor Red; $script:fail++ }
}
function Step([string]$t) { Write-Host ("== {0}" -f $t) -ForegroundColor Cyan }
function Did([string]$t) { Write-Host ("   {0}" -f $t) -ForegroundColor Green }
function Warn([string]$t) { Write-Host ("   {0}" -f $t) -ForegroundColor Yellow }
function Info([string]$t) { Write-Host ("   {0}" -f $t) -ForegroundColor DarkGray }

function Get-Bundles {
    if (-not (Test-Path -LiteralPath $profilePkg)) { return @() }
    return @((Get-Content -LiteralPath $profilePkg -Raw | ConvertFrom-Json).dsh.profile.bundles)
}

# ---------------------------------------------------------------- 前置
Write-Host 'dsh-jailbreak' -ForegroundColor Cyan
Info "DSH_HOME = $DshHome"
Info "profile  = $profileDir"
if (-not (Test-Path -LiteralPath $profileDir)) { Write-Host "环境错误：找不到 $profileDir" -ForegroundColor Red; exit 2 }

$bundles0 = Get-Bundles
$hasLocal = Test-Path -LiteralPath (Join-Path $pluginDir 'index.mjs')
$hasPackage = (Test-Path -LiteralPath (Join-Path $pkgDir 'lib\index.mjs')) -and ($bundles0 -contains 'dsh-jailbreak')
$layout = if ($hasLocal -and $hasPackage) { 'both' } elseif ($hasLocal) { 'local' } elseif ($hasPackage) { 'package' } else { 'none' }
$activeRoot = if ($hasLocal) { $pluginDir } else { Join-Path $pkgDir 'lib' }

$modeText = if ($Remove) { 'REMOVE（拆掉本地安装）' }
    elseif ($Check) { 'CHECK（只读）' }
    elseif ($DryRun) { 'DRY-RUN（不写文件）' }
    else { 'APPLY（本地安装 + 自检）' }
if ($Restart) { $modeText += ' + RESTART' }
Info "布局     = $layout"
Info "模式     = $modeText"
if ($layout -eq 'both') { Warn '两种布局同时存在：注入会跑两遍，建议 -Remove 掉本地那份。' }
Write-Host ''

# ---------------------------------------------------------------- 移除（-Remove）
if ($Remove) {
    Step '移除本地目录安装'
    if (-not (Test-Path -LiteralPath $pluginDir)) {
        Did '本地目录不存在，无需移除'
    } elseif ($DryRun) {
        Did "将删除 $pluginDir"
    } else {
        Remove-Item -LiteralPath $pluginDir -Recurse -Force
        Did "已删除 $pluginDir"
    }

    if (Test-Path -LiteralPath $patchFile) {
        $lines = @(Get-Content -LiteralPath $patchFile)
        $idx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -notmatch '^\s*-\s*insert:\s*$') { continue }
            $to = [Math]::Min($lines.Count - 1, $i + 12)
            if ((($lines[$i..$to]) -join "`n") -match 'dsh-jailbreak') { $idx = $i }
        }
        if ($idx -lt 0) {
            Did 'patch 里没有本地挂载块'
        } else {
            $cut = $idx
            while ($cut -gt 0) {
                $prev = $lines[$cut - 1]
                if ($prev -match '^\s*$') { $cut--; continue }
                if ($prev -match '^\s*#' -and $prev -match 'dsh-jailbreak|破甲词|插件本体|单文件') { $cut--; continue }
                break
            }
            $kept = @($lines[0..([Math]::Max(0, $cut - 1))] | Where-Object { $null -ne $_ })
            if ($DryRun) {
                Did ("将切掉第 {0}-{1} 行（本地挂载块，system-prompt 覆盖保留）" -f ($cut + 1), $lines.Count)
            } else {
                $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                $backupDir = Join-Path $projectRoot "backup\remove-$stamp"
                New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
                Copy-Item -LiteralPath $patchFile -Destination (Join-Path $backupDir 'cordis.patch.yml') -Force
                Set-Content -LiteralPath $patchFile -Value (($kept -join "`r`n").TrimEnd() + "`r`n") -Encoding utf8NoBOM
                Did ("已切掉第 {0}-{1} 行（备份在 {2}）" -f ($cut + 1), $lines.Count, $backupDir)
            }
        }
    }

    Write-Host ''
    Write-Host '本地安装已拆。要改用插件管理器版本，在「插件 → 添加插件」里填：' -ForegroundColor Yellow
    Write-Host '  https://github.com/cwen63970-coder/dsh-jailbreak.git' -ForegroundColor Yellow
    Write-Host '装完重启 DSH。system-prompt 覆盖保留在 profile 里，不影响管理器版本。' -ForegroundColor Yellow
    exit 0
}

# ---------------------------------------------------------------- 1. 安装（仅 local 布局且非 -Check）
if (-not $Check) {
    Step '1/3 安装'
    if ($layout -eq 'package') {
        Warn '已通过插件管理器安装（bundles 里有 dsh-jailbreak）：跳过本地目录安装，避免双重注入'
    } else {
        if (-not (Test-Path -LiteralPath $libDir)) { Write-Host "环境错误：找不到 $libDir" -ForegroundColor Red; exit 2 }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backupDir = Join-Path $projectRoot "backup\apply-$stamp"
        if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $pluginDir | Out-Null }

        $srcFiles = @(Get-ChildItem -LiteralPath $libDir -File | Where-Object { $_.Name -match '\.(mjs|js|md)$' })
        if ($srcFiles.Count -eq 0) { Write-Host "环境错误：$libDir 里没有可安装文件" -ForegroundColor Red; exit 2 }
        foreach ($f in $srcFiles) {
            $dst = Join-Path $pluginDir $f.Name
            $same = (Test-Path -LiteralPath $dst) -and ((Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash)
            if ($same) { Did ("不变 {0}" -f $f.Name); continue }
            if ($DryRun) { Did ("将写入 {0} ({1} B)" -f $f.Name, $f.Length); continue }
            Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
            Did ("写入 {0} ({1} B)" -f $f.Name, $f.Length)
        }

        Step '2/3 profile 配置'
        function Backup-File([string]$path, [string]$name) {
            if ($DryRun) { return }
            if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Force -Path $backupDir | Out-Null }
            Copy-Item -LiteralPath $path -Destination (Join-Path $backupDir $name) -Force
        }
        $patch = Get-Content -LiteralPath $patchFile -Raw
        $patchChanged = $false
        if ($patch -notmatch 'includeHarnessIdentity:\s*false') {
            $patch = $patch.TrimEnd() + "`r`n`r`n" + $SYSTEM_PROMPT_BLOCK + "`r`n"
            $patchChanged = $true
            Did '追加 system-prompt 覆盖'
        } else { Did 'system-prompt 覆盖已存在' }
        if ($patch -notmatch 'plugins/dsh-jailbreak/index\.mjs') {
            $patch = $patch.TrimEnd() + "`r`n`r`n" + $INSERT_BLOCK + "`r`n"
            $patchChanged = $true
            Did '追加插件挂载行'
        } else { Did '插件挂载行已存在' }
        if ($patchChanged) {
            if ($DryRun) { Did '（DryRun：将写入 cordis.patch.yml）' }
            else { Backup-File $patchFile 'cordis.patch.yml'; Set-Content -LiteralPath $patchFile -Value $patch -Encoding utf8NoBOM }
        }

        $pkg = Get-Content -LiteralPath $profilePkg -Raw | ConvertFrom-Json
        $bundles = @($pkg.dsh.profile.bundles)
        if ($bundles -contains 'dsh-purge') {
            $pkg.dsh.profile.bundles = @($bundles | Where-Object { $_ -ne 'dsh-purge' })
            if ($DryRun) { Did '（DryRun：将从 bundles 摘掉 dsh-purge）' }
            else {
                Backup-File $profilePkg 'package.json'
                ($pkg | ConvertTo-Json -Depth 20) + "`n" | Set-Content -LiteralPath $profilePkg -Encoding utf8NoBOM
                Did '已从 bundles 摘掉 dsh-purge'
            }
        } else { Did 'bundles 已无 dsh-purge' }

        if (Test-Path -LiteralPath $purgePkg) {
            $purge = Get-Content -LiteralPath $purgePkg -Raw | ConvertFrom-Json
            if ($purge.dsh.PSObject.Properties.Name -contains 'client') {
                $purge.dsh.PSObject.Properties.Remove('client')
                if ($DryRun) { Did '（DryRun：将删除 dsh-purge 的 client 字段）' }
                else {
                    Backup-File $purgePkg 'dsh-purge-package.json'
                    ($purge | ConvertTo-Json -Depth 20) + "`n" | Set-Content -LiteralPath $purgePkg -Encoding utf8NoBOM
                    Did '已删除 dsh-purge 的 client 字段（dock 不再加载）'
                }
            } else { Did 'dsh-purge 已无 client 字段' }
        } else { Did '未安装 dsh-purge，跳过' }
    }

    # system-prompt 覆盖与安装方式无关：管理器装包时也要写，否则官方身份段只能靠运行时剥
    if ($layout -eq 'package') {
        Step '2/3 profile 配置'
        $patch = Get-Content -LiteralPath $patchFile -Raw
        if ($patch -match 'includeHarnessIdentity:\s*false') {
            Did 'system-prompt 覆盖已存在'
        } elseif ($DryRun) {
            Did '（DryRun：将追加 system-prompt 覆盖）'
        } else {
            $stamp2 = Get-Date -Format 'yyyyMMdd-HHmmss'
            $backupDir2 = Join-Path $projectRoot "backup\apply-$stamp2"
            New-Item -ItemType Directory -Force -Path $backupDir2 | Out-Null
            Copy-Item -LiteralPath $patchFile -Destination (Join-Path $backupDir2 'cordis.patch.yml') -Force
            Set-Content -LiteralPath $patchFile -Value ($patch.TrimEnd() + "`r`n`r`n" + $SYSTEM_PROMPT_BLOCK + "`r`n") -Encoding utf8NoBOM
            Did '追加 system-prompt 覆盖'
        }
    }
    Write-Host ''
}

# ---------------------------------------------------------------- 2. 自检
Step '3/3 自检'
$required = 'index.mjs', 'identity.js', 'capability-protocol.js', 'net-scope.js', 'phase1-keep.js', 'prompt-inject.md'
if ($layout -eq 'none') {
    Check-Assert '存在一种安装布局' $false '本地目录与管理器包都没找到'
} else {
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $activeRoot $_)) })
    Check-Assert ("插件文件齐全（$layout）") ($missing.Count -eq 0) ($missing -join ', ')
}

if (Test-Path -LiteralPath $patchFile) {
    $patchNow = Get-Content -LiteralPath $patchFile -Raw
    $mounted = ($patchNow -match 'plugins/dsh-jailbreak/index\.mjs') -or ((Get-Bundles) -contains 'dsh-jailbreak')
    Check-Assert 'dsh-jailbreak 已挂载' $mounted
    Check-Assert 'patch 有 system-prompt 覆盖' ($patchNow -match 'includeHarnessIdentity:\s*false')
    Check-Assert 'patch 不再挂 dsh-purge' (-not ($patchNow -match 'id:\s*dsh-purge\b'))
} else { Check-Assert 'cordis.patch.yml 存在' $false $patchFile }

$b = Get-Bundles
Check-Assert 'bundles 无 dsh-purge' (-not ($b -contains 'dsh-purge')) ($b -join ', ')

if (Test-Path -LiteralPath $purgePkg) {
    $p = Get-Content -LiteralPath $purgePkg -Raw | ConvertFrom-Json
    Check-Assert 'dsh-purge 无 client(dock)' (-not ($p.dsh.PSObject.Properties.Name -contains 'client'))
}

if (Test-Path -LiteralPath $injectFile) {
    $item = Get-Item -LiteralPath $injectFile
    Check-Assert '破甲词文件存在' ($item.Length -gt 0) ("size={0}" -f $item.Length)
    Info ("prompt-inject.md size={0} sha256={1}" -f $item.Length, (Get-FileHash -LiteralPath $injectFile -Algorithm SHA256).Hash)
} else { Check-Assert '破甲词文件存在' $false $injectFile }

$hostProc = @(Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -notmatch '--type=' } | Sort-Object CreationDate | Select-Object -First 1)
$needRestart = $false
if ($hostProc -and $layout -ne 'none' -and $ProfileName -eq 'desktop') {
    $started = $hostProc.CreationDate
    # 判据取三处最新时间：插件文件、profile 的 package.json（bundles 改动）、cordis.patch.yml
    $candidates = @()
    $candidates += @(Get-ChildItem -LiteralPath $activeRoot -File | Select-Object -ExpandProperty LastWriteTime)
    foreach ($f in @($profilePkg, $patchFile)) { if (Test-Path -LiteralPath $f) { $candidates += (Get-Item -LiteralPath $f).LastWriteTime } }
    $newest = ($candidates | Sort-Object -Descending | Select-Object -First 1)
    $needRestart = $started -lt $newest
    Check-Assert '插件已加载（配置早于宿主启动）' (-not $needRestart) ("host={0:HH:mm:ss} 最新配置={1:HH:mm:ss}" -f $started, $newest)
} elseif ($ProfileName -ne 'desktop') {
    Info "profile '$ProfileName' 不是当前运行的桌面端 profile：跳过“是否已加载”检查"
}

if ($layout -ne 'none' -and (Test-Path -LiteralPath (Join-Path $activeRoot 'index.mjs'))) {
    $env:JAILBREAK_ROOT = $activeRoot
    $env:JAILBREAK_INJECT = Join-Path $activeRoot 'prompt-inject.md'
    $jsOut = & node '--input-type=module' '-e' $TEST_JS 2>&1
    $jsCode = $LASTEXITCODE
    Remove-Item Env:JAILBREAK_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:JAILBREAK_INJECT -ErrorAction SilentlyContinue
    Check-Assert '行为自检（19 项断言）' ($jsCode -eq 0) (($jsOut | Select-Object -Last 2) -join ' | ')
    if ($jsCode -ne 0) { $jsOut | Where-Object { $_ -match '^FAIL' } | ForEach-Object { Warn $_ } }
}

Write-Host ''
if ($fail -gt 0) { Write-Host ("自检 FAIL {0} 项。" -f $fail) -ForegroundColor Red; exit 1 }
Write-Host '自检全部通过。' -ForegroundColor Green

# ---------------------------------------------------------------- 3. 重启（可选）
if ($Restart) {
    if (-not $hostProc) {
        if (Test-Path -LiteralPath $exePath) { Start-Process -FilePath $exePath; Write-Host '宿主原本未运行，已启动。' -ForegroundColor Green; exit 0 }
        Write-Host "环境错误：找不到 $exePath" -ForegroundColor Red
        exit 2
    }
    Write-Host ''
    Write-Host ("重启：结束 PID {0} 并重新启动，当前会话会中断。" -f $hostProc.ProcessId) -ForegroundColor Yellow
    & taskkill.exe /PID $hostProc.ProcessId /T /F 2>&1 | Out-Null
    $deadline = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $deadline -and (Get-Process -Id $hostProc.ProcessId -ErrorAction SilentlyContinue)) { Start-Sleep -Milliseconds 300 }
    if (Get-Process -Id $hostProc.ProcessId -ErrorAction SilentlyContinue) { Stop-Process -Id $hostProc.ProcessId -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2 }
    $launch = if ($hostProc.ExecutablePath) { $hostProc.ExecutablePath } else { $exePath }
    Start-Process -FilePath $launch
    Start-Sleep -Seconds 4
    $after = @(Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine -notmatch '--type=' })
    if ($after.Count -gt 0) { Write-Host ("已启动：PID {0}" -f $after[0].ProcessId) -ForegroundColor Green; exit 0 }
    Write-Host '启动后未检测到主进程，请手动打开。' -ForegroundColor Red
    exit 1
}

if ($needRestart) {
    Write-Host '配置已更新但宿主还是旧进程：下次启动才生效。加 -Restart 让它立即生效。' -ForegroundColor Yellow
    exit 3
}
Write-Host '无需重启，当前进程已在用最新插件。' -ForegroundColor Green
exit 0
