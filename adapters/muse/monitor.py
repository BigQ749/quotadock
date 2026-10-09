#!/usr/bin/env python3
"""Sync Muse.ai weekly usage into QuotaDock custom-data/muse.json."""
from __future__ import annotations

import argparse
import base64
import ctypes
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from ctypes import wintypes
from datetime import datetime, timezone
from pathlib import Path

UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
)
STATE = Path(os.environ["LOCALAPPDATA"]) / "QuotaDock"
CRED = STATE / "muse_credentials.json"
OUT = STATE / "custom-data" / "muse.json"
CACHE = STATE / "muse-sync-state.json"
KNOWN_ACTION = "40939e200144999b87d28e7add74c86809ca484daf"


class DATA_BLOB(ctypes.Structure):
    _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]


def unprotect(b64: str) -> str:
    raw = base64.b64decode(b64)
    bi = DATA_BLOB(len(raw), ctypes.create_string_buffer(raw, len(raw)))
    bo = DATA_BLOB()
    if not ctypes.windll.crypt32.CryptUnprotectData(
        ctypes.byref(bi), None, None, None, None, 0, ctypes.byref(bo)
    ):
        raise OSError("DPAPI unprotect failed")
    try:
        return ctypes.string_at(bo.pbData, bo.cbData).decode("utf-8")
    finally:
        ctypes.windll.kernel32.LocalFree(bo.pbData)


def load_cookie() -> str:
    data = json.loads(CRED.read_text(encoding="utf-8"))
    return unprotect(data["cookieDpapi"])


def load_action() -> str | None:
    if CACHE.exists():
        try:
            return json.loads(CACHE.read_text(encoding="utf-8")).get("actionId")
        except Exception:
            return None
    return None


def save_action(action_id: str) -> None:
    CACHE.write_text(json.dumps({"actionId": action_id}, indent=2), encoding="utf-8")


def http(url: str, cookie: str, data: bytes | None = None, headers: dict | None = None, method: str | None = None):
    h = {"User-Agent": UA, "Cookie": cookie}
    if headers:
        h.update(headers)
    req = urllib.request.Request(url, data=data, headers=h, method=method)
    with urllib.request.urlopen(req, timeout=45) as resp:
        return resp.geturl(), resp.status, resp.read().decode("utf-8", errors="replace"), dict(resp.headers)


def post_action(cookie: str, action_id: str) -> tuple[int, str]:
    body = json.dumps([{"includeAgreement": True}]).encode("utf-8")
    try:
        _, status, text, _ = http(
            "https://muse.ai/",
            cookie,
            data=body,
            method="POST",
            headers={
                "Content-Type": "text/plain;charset=UTF-8",
                "Accept": "text/x-component",
                "Next-Action": action_id,
                "Origin": "https://muse.ai",
                "Referer": "https://muse.ai/",
                "Sec-Fetch-Dest": "empty",
                "Sec-Fetch-Mode": "cors",
                "Sec-Fetch-Site": "same-origin",
            },
        )
        return status, text
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", errors="replace")


def discover_action(cookie: str) -> str | None:
    """Fallback: scan homepage + settings chunks for fetchSubscriptionAction."""
    final, _, html, _ = http("https://muse.ai/", cookie)
    if "auth.muse.ai" in final:
        raise RuntimeError("NEED_LOGIN")
    chunks = sorted(set(re.findall(r"/_next/static/chunks/[^\"'?]+\.js", html)))
    # also settings
    try:
        _, _, html2, _ = http("https://muse.ai/settings", cookie)
        chunks = sorted(set(chunks) | set(re.findall(r"/_next/static/chunks/[^\"'?]+\.js", html2)))
    except Exception:
        pass
    pat = re.compile(
        r'createServerReference\)?\("([a-f0-9]+)"[^"]*"fetchSubscriptionAction"',
        re.S,
    )
    checked = 0
    for c in chunks:
        if checked >= 120:
            break
        try:
            req = urllib.request.Request("https://muse.ai" + c, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=30) as resp:
                body = resp.read().decode("utf-8", errors="replace")
        except Exception:
            continue
        checked += 1
        m = pat.search(body)
        if m:
            return m.group(1)
        if "fetchSubscriptionAction" in body:
            m2 = re.search(
                r'createServerReference\)?\("([a-f0-9]+)".{0,160}fetchSubscriptionAction',
                body,
                re.S,
            )
            if m2:
                return m2.group(1)
    return None


def parse_subscription(text: str) -> dict:
    payload = None
    for line in text.splitlines():
        if "percentUsed" in line or '"subscription"' in line:
            idx = line.find("{")
            if idx >= 0:
                try:
                    payload = json.loads(line[idx:])
                    break
                except Exception:
                    pass
    if not isinstance(payload, dict):
        raise RuntimeError("PARSE_FAIL")
    sub = payload.get("subscription") or payload
    usage = sub.get("usage") if isinstance(sub, dict) else {}
    percent_used = int(usage.get("percentUsed"))
    resets_at = usage.get("resetsAt")
    tier = sub.get("tier") if isinstance(sub, dict) else {}
    plan = "Muse"
    if isinstance(tier, dict):
        plan = tier.get("name") or tier.get("displayName") or plan
    reset_text = "重置时间未知"
    if resets_at:
        reset_text = (
            datetime.fromtimestamp(int(resets_at), tz=timezone.utc)
            .astimezone()
            .strftime("%m-%d %H:%M 重置")
        )
    remaining = max(0, min(100, 100 - percent_used))
    return {
        "percent_used": percent_used,
        "remaining": remaining,
        "plan": plan,
        "reset_text": reset_text,
        "usage_label": sub.get("usageRowValueLabel") if isinstance(sub, dict) else None,
    }


def write_snapshot(ok: bool, parsed: dict | None, err: str | None) -> None:
    now = datetime.now().astimezone()
    now_s = now.isoformat(timespec="seconds")
    if ok and parsed:
        out = {
            "title": "Muse",
            "badge": str(parsed["plan"]),
            "status": f"已同步 {now.strftime('%H:%M')}",
            "updatedAt": now_s,
            "lastSuccessAt": now_s,
            "lastAttemptAt": now_s,
            "syncStatus": "success",
            "lastError": None,
            "windows": [
                {
                    "label": "周额度",
                    "remainingPercent": parsed["remaining"],
                    "resetText": parsed["reset_text"],
                }
            ],
        }
    else:
        prev = {}
        if OUT.exists():
            try:
                prev = json.loads(OUT.read_text(encoding="utf-8"))
            except Exception:
                prev = {}
        out = {
            "title": prev.get("title") or "Muse",
            "badge": prev.get("badge") or "Muse",
            "status": f"同步失败 {now.strftime('%H:%M')}",
            "updatedAt": now_s,
            "lastSuccessAt": prev.get("lastSuccessAt"),
            "lastAttemptAt": now_s,
            "syncStatus": "error",
            "lastError": err or "unknown",
            "windows": prev.get("windows")
            or [{"label": "周额度", "remainingPercent": 0, "resetText": "—"}],
        }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    tmp = OUT.with_suffix(".tmp")
    tmp.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(OUT)


def sync_once() -> int:
    if not CRED.exists():
        write_snapshot(False, None, "missing credentials")
        print("NO_CRED")
        return 2
    cookie = load_cookie()
    candidates = []
    cached = load_action()
    if cached:
        candidates.append(cached)
    if KNOWN_ACTION not in candidates:
        candidates.append(KNOWN_ACTION)

    last_err = None
    for action in candidates:
        status, text = post_action(cookie, action)
        if status == 200 and "percentUsed" in text:
            parsed = parse_subscription(text)
            save_action(action)
            write_snapshot(True, parsed, None)
            print(
                f"OK remaining={parsed['remaining']} used={parsed['percent_used']} "
                f"plan={parsed['plan']} reset={parsed['reset_text']}"
            )
            return 0
        if status == 404 or "Server action not found" in text:
            last_err = f"stale action {action[:12]}"
            continue
        if "auth.muse.ai" in text or status in (401, 403):
            write_snapshot(False, None, "NEED_LOGIN")
            print("NEED_LOGIN")
            return 3
        last_err = f"status={status}"

    # rediscover
    try:
        new_id = discover_action(cookie)
    except Exception as e:
        write_snapshot(False, None, str(e))
        print("DISCOVER_FAIL", e)
        return 4
    if not new_id:
        write_snapshot(False, None, last_err or "NO_ACTION")
        print("NO_ACTION")
        return 5
    status, text = post_action(cookie, new_id)
    if status == 200 and "percentUsed" in text:
        parsed = parse_subscription(text)
        save_action(new_id)
        write_snapshot(True, parsed, None)
        print(
            f"OK remaining={parsed['remaining']} used={parsed['percent_used']} "
            f"plan={parsed['plan']} reset={parsed['reset_text']} action=rediscovered"
        )
        return 0
    write_snapshot(False, None, f"rediscover failed status={status}")
    print("FAIL", status)
    return 6


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--loop", action="store_true")
    ap.add_argument("--interval", type=int, default=120)
    args = ap.parse_args()
    if not args.loop:
        return sync_once()
    while True:
        try:
            sync_once()
        except Exception as e:
            write_snapshot(False, None, str(e))
            print("ERR", e)
        time.sleep(max(30, args.interval))


if __name__ == "__main__":
    sys.exit(main())