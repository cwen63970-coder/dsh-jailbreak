/**
 * net-scope.js 桩：identity.js 只用到 ownServerNote()。
 * 上游实现返回 ""（没有自建服务器备注），这里保持同样语义，
 * 从而切断 identity.js -> net-scope.js -> core.js -> desktop.js 那条宿主补丁链。
 */
export function ownServerNote() {
  return "";
}
