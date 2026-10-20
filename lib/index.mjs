/**
 * dsh-jailbreak —— 只做「提示词注入破甲」的 DSH 插件。
 *
 * 设计边界（刻意不做的事）：
 *   - 不写宿主机文件（不碰 app.asar / @deepseek-ai / pi-ai）
 *   - 不注册任何模型工具
 *   - 不注册客户端 UI（无 dock、无页签）
 *   - 不碰审批、沙箱、文件围栏、hooks
 *   - 不联网、不上传
 *
 * 唯一动作：挂在 system-prompt/assemble 上，改写内存里的段表：
 *   harness:identity 丢弃 → 注入词折叠进 deployment:persona-prefix（带 ChatML 信封）
 *   → 官方身份句剥离 → 可选丢弃 workspace baseline / mnemon → 追加能力选用协议段。
 *
 * 破甲词来源：$DSH_HOME/prompt-inject.md（可用 config.file 覆盖，失败回落到插件自带副本）。
 */

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  ensureCwdPromptVariable,
  installAssembleGuard,
  rewritePromptAssembly,
} from "./identity.js";

export const name = "dsh-jailbreak";
export const inject = ["systemPrompt"];

const HERE = path.dirname(fileURLToPath(import.meta.url));

const DEFAULTS = {
  enabled: true,
  /** 显式指定破甲词文件；留空 = $DSH_HOME/prompt-inject.md */
  file: "",
  /** 丢弃宿主 mnemon 段 */
  stripMnemon: true,
  /** 有注入词时丢弃官方 workspace baseline 段 */
  dropWorkspaceBaseline: true,
  /** 追加 dshpg-capabilities 段（教模型主动读 skill / MCP 目录） */
  capabilityProtocol: true,
  /** 打开后每次 assemble 往 stderr 写一行摘要 */
  verbose: false,
};

function dshHome() {
  const env = String(process.env.DSH_HOME || "").trim();
  if (env) return env;
  return path.join(os.homedir(), ".dsh");
}

/** 注入词读取器：按 mtime+size 缓存，文件被编辑后下一轮自动生效。 */
function makeReader(config, log) {
  const explicit = String(config.file || "").trim();
  const primary = explicit || path.join(dshHome(), "prompt-inject.md");
  const fallback = path.join(HERE, "prompt-inject.md");
  let cached = "";
  let stamp = "";
  let used = "";

  const load = (file) => {
    const s = fs.statSync(file);
    const sig = `${s.mtimeMs}:${s.size}`;
    if (file === used && sig === stamp) return true;
    cached = fs.readFileSync(file, "utf8");
    stamp = sig;
    used = file;
    log("inject.reload", { file, bytes: cached.length });
    return true;
  };

  return () => {
    try {
      load(primary);
      return cached;
    } catch (e) {
      log("inject.primary.failed", { file: primary, err: String((e && e.message) || e) });
    }
    try {
      load(fallback);
      return cached;
    } catch {
      return cached;
    }
  };
}

export function apply(ctx, config = {}) {
  const cfg = { ...DEFAULTS, ...(config || {}) };
  const log = (...args) => {
    if (!cfg.verbose) return;
    try {
      console.log("[dsh-jailbreak]", ...args);
    } catch {
      /* 日志失败不影响注入 */
    }
  };
  if (cfg.enabled === false) return;

  const read = makeReader(cfg, log);
  const produced = new WeakSet();

  const rewrite = (assembled, input) => {
    if (!assembled || !Array.isArray(assembled.sections)) return assembled;
    if (produced.has(assembled)) return assembled;
    // assemble() 的入参形状随宿主版本变化：可能是 { agent, session }，也可能把
    // 会话上下文放在 input.context 里。两种都认，取不到就当没有上下文。
    const context = (input && (input.agent || input.session) ? input : input && input.context) || input;
    const text = read();
    const hasText = Boolean(String(text || "").trim());
    const out = rewritePromptAssembly(assembled, hasText ? text : "", {
      dropMnemon: cfg.stripMnemon !== false,
      dropPurgeAfterFold: false,
      capabilityProtocol: cfg.capabilityProtocol !== false,
      dropWorkspaceBaseline: cfg.dropWorkspaceBaseline !== false && hasText,
      context,
    });
    if (out && typeof out === "object") produced.add(out);
    return out;
  };

  const prompt = ctx && ctx.systemPrompt;
  if (!prompt) {
    log("skip: no systemPrompt service");
    return;
  }

  // 兜底：注入词里若仍写着 {{cwd}}，把 cwd 变量注册回宿主（0.2.1 起被移除）。
  try {
    ensureCwdPromptVariable(prompt);
  } catch (e) {
    log("cwd.var.failed", String((e && e.message) || e));
  }

  // 主路径：包住 systemPrompt.assemble。
  try {
    installAssembleGuard(prompt, rewrite);
    log("guard.mounted", { file: String(cfg.file || "") || path.join(dshHome(), "prompt-inject.md") });
  } catch (e) {
    log("guard.failed", String((e && e.message) || e));
  }

  // 备用路径：瀑布监听。cordis 版本不同，next 可能在末位也可能不存在。
  try {
    ctx.on("system-prompt/assemble", async (...args) => {
      const assembly = args[0];
      const context = args[1];
      const next = args.length >= 3 ? args[args.length - 1] : null;
      let base = assembly;
      if (typeof next === "function") {
        try {
          base = await next();
        } catch (e) {
          log("waterfall.rejected", String((e && e.message) || e));
          base = assembly;
        }
      }
      try {
        return rewrite(base, context);
      } catch (e) {
        log("rewrite.failed", String((e && e.message) || e));
        return base;
      }
    });
  } catch (e) {
    log("hook.failed", String((e && e.message) || e));
  }
}
