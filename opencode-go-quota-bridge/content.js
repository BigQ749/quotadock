(() => {
  const BRIDGE_URL = "http://127.0.0.1:45731/opencode";
  const POLL_MS = 60 * 1000;

  function formatReset(seconds) {
    const value = Math.max(0, Number(seconds) || 0);
    if (value <= 0) return "即将重置";
    const days = Math.floor(value / 86400);
    const hours = Math.floor((value % 86400) / 3600);
    const minutes = Math.floor((value % 3600) / 60);
    const parts = [];
    if (days > 0) parts.push(`${days} 天`);
    if (hours > 0 || days > 0) parts.push(`${hours} 小时`);
    if (minutes > 0 || parts.length === 0) parts.push(`${minutes} 分钟`);
    return `约 ${parts.join(" ")}后重置`;
  }

  function parseDurationSeconds(text) {
    let total = 0;
    let found = false;
    const pattern = /(\d+(?:\.\d+)?)\s*(天|日|小时|时|分钟|分|秒|days?|hours?|minutes?|seconds?)/gi;
    for (const match of text.matchAll(pattern)) {
      found = true;
      const value = Number(match[1]);
      const unit = match[2].toLowerCase();
      if (unit === "天" || unit === "日" || unit === "day" || unit === "days") total += value * 86400;
      else if (unit === "小时" || unit === "时" || unit === "hour" || unit === "hours") total += value * 3600;
      else if (unit === "分钟" || unit === "分" || unit === "minute" || unit === "minutes") total += value * 60;
      else total += value;
    }
    return found ? Math.max(0, Math.ceil(total)) : null;
  }

  function parseEmbedded() {
    const html = document.documentElement?.outerHTML || "";
    const read = (name, kind, mode, title) => {
      const pattern = new RegExp(`${name}:\\$R\\[\\d+\\]=\\{status:"([^"]+)",resetInSec:(\\d+),usagePercent:([\\d.]+)\\}`);
      const match = html.match(pattern);
      if (!match || match[1] !== "ok") return null;
      const used = Number(match[3]);
      const resetInSec = Math.max(0, Number(match[2]) || 0);
      return {
        kind,
        title,
        usedPercent: used,
        remainingPercent: Math.max(0, Math.min(100, 100 - used)),
        resetText: formatReset(resetInSec),
        resetInSec,
        resetAt: new Date(Date.now() + resetInSec * 1000).toISOString(),
        resetMode: mode
      };
    };
    const windows = [
      read("rollingUsage", "five_hour", "rolling", "5 小时额度"),
      read("weeklyUsage", "week", "weekly", "周额度"),
      read("monthlyUsage", "month", "monthly", "月额度")
    ];
    return windows.every(Boolean) ? windows : null;
  }

  function parseVisible() {
    const text = (document.body?.innerText || "").replace(/\s+/g, " ").trim();
    const definitions = [
      ["滚动用量", "每周用量", "five_hour", "rolling", "5 小时额度"],
      ["每周用量", "每月用量", "week", "weekly", "周额度"],
      ["每月用量", "达到使用限额", "month", "monthly", "月额度"]
    ];
    const windows = [];
    for (const [label, nextLabel, kind, mode, title] of definitions) {
      const pattern = new RegExp(`${label}\\s+(\\d+(?:\\.\\d+)?)\\s*%\\s*重置于\\s*(.+?)\\s+(?=${nextLabel})`);
      const match = text.match(pattern);
      if (!match) return null;
      const used = Number(match[1]);
      const resetInSec = parseDurationSeconds(match[2]);
      windows.push({
        kind,
        title,
        usedPercent: used,
        remainingPercent: Math.max(0, Math.min(100, 100 - used)),
        resetText: `重置于 ${match[2]}`,
        ...(resetInSec === null ? {} : {
          resetInSec,
          resetAt: new Date(Date.now() + resetInSec * 1000).toISOString()
        }),
        resetMode: mode
      });
    }
    return windows;
  }

  async function sync() {
    const windows = parseEmbedded() || parseVisible();
    if (!windows) return;
    try {
      await fetch(BRIDGE_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        credentials: "omit",
        body: JSON.stringify({ provider: "opencode", windows })
      });
    } catch (_) {
      // The desktop bridge may not be running; the page remains unaffected.
    }
  }

  sync();
  window.setInterval(sync, POLL_MS);
})();
