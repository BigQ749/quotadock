#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Sync Cursor Grok Bot weekly usage into QuotaDock custom-provider JSON.

Prefer the signed-in Grok Bot desktop app account (sand-secrets.json, OSCrypt),
fall back to Cursor IDE accessToken in state.vscdb. Never print tokens.
"""

from __future__ import annotations

import argparse
import base64
import ctypes
import json
import os
import sqlite3
import sys
import time
import urllib.error
import urllib.request
from ctypes import wintypes
from datetime import datetime
from pathlib import Path
from typing import Optional, Tuple

try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
except ImportError:  # pragma: no cover
    AESGCM = None  # type: ignore

STATE_DIR = Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "QuotaDock"
OUT = Path(
    os.environ.get(
        "QUOTADOCK_GROKBOT_DATA",
        str(STATE_DIR / "custom-data" / "grokbot.json"),
    )
)
LOCK = STATE_DIR / "grokbot-sync.lock"
APPDATA = Path(os.environ.get("APPDATA", str(Path.home())))
GROK_BOT_DIR = APPDATA / "Grok Bot"
SAND_SECRETS = GROK_BOT_DIR / "sand-secrets.json"
LOCAL_STATE = GROK_BOT_DIR / "Local State"
CURSOR_DB = APPDATA / "Cursor" / "User" / "globalStorage" / "state.vscdb"
ENDPOINT = "https://cursor.com/api/dashboard/get-sand-usage-status"
TOKEN_KEY = "cursorAuth/accessToken"
POLL_SEC = int(os.environ.get("QUOTADOCK_GROKBOT_POLL_SEC", "60"))


class DATA_BLOB(ctypes.Structure):
    _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]


def iso_now() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def atomic_write(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(path)


def b64url_decode(segment: str) -> bytes:
    pad = "=" * ((4 - len(segment) % 4) % 4)
    return base64.urlsafe_b64decode(segment + pad)


def jwt_claims(token: str) -> Optional[dict]:
    parts = token.split(".")
    if len(parts) != 3:
        return None
    try:
        return json.loads(b64url_decode(parts[1]))
    except Exception:
        return None


def dpapi_unprotect(data: bytes) -> bytes:
    blob_in = DATA_BLOB(len(data), ctypes.create_string_buffer(data, len(data)))
    blob_out = DATA_BLOB()
    if not ctypes.windll.crypt32.CryptUnprotectData(
        ctypes.byref(blob_in), None, None, None, None, 0, ctypes.byref(blob_out)
    ):
        raise OSError("CryptUnprotectData failed")
    try:
        return ctypes.string_at(blob_out.pbData, blob_out.cbData)
    finally:
        ctypes.windll.kernel32.LocalFree(blob_out.pbData)


def load_oscrypt_key() -> Optional[bytes]:
    if not LOCAL_STATE.is_file():
        return None
    try:
        ls = json.loads(LOCAL_STATE.read_text(encoding="utf-8"))
        enc = base64.b64decode(ls["os_crypt"]["encrypted_key"])
    except Exception:
        return None
    if not enc.startswith(b"DPAPI"):
        return None
    try:
        return dpapi_unprotect(enc[5:])
    except Exception:
        return None


def decrypt_safe_storage(value: str, aes_key: bytes) -> str:
    if AESGCM is None:
        raise RuntimeError("cryptography package required")
    raw = base64.b64decode(value)
    if not (raw.startswith(b"v10") or raw.startswith(b"v11")):
        return dpapi_unprotect(raw).decode("utf-8")
    nonce, cipher = raw[3:15], raw[15:]
    return AESGCM(aes_key).decrypt(nonce, cipher, None).decode("utf-8")


def read_grok_bot_token() -> Tuple[Optional[str], Optional[str]]:
    if not SAND_SECRETS.is_file():
        return None, None
    aes_key = load_oscrypt_key()
    if aes_key is None:
        return None, None
    try:
        sec = json.loads(SAND_SECRETS.read_text(encoding="utf-8"))
        blob = sec.get("cursor-accounts")
        data = json.loads(blob) if isinstance(blob, str) else blob
        if not isinstance(data, dict):
            return None, None
        active = data.get("active")
        accounts = data.get("accounts") or {}
        acct = accounts.get(active) if isinstance(accounts, dict) else None
        if not isinstance(acct, dict):
            return None, None
        enc_token = acct.get("cursor-access-token")
        if not isinstance(enc_token, str) or not enc_token:
            return None, None
        token = decrypt_safe_storage(enc_token, aes_key)
        email = None
        profile = acct.get("cursor-account-profile")
        if isinstance(profile, str) and profile:
            try:
                if not profile.lstrip().startswith("{"):
                    profile = decrypt_safe_storage(profile, aes_key)
                obj = json.loads(profile) if isinstance(profile, str) else profile
                if isinstance(obj, dict) and isinstance(obj.get("email"), str):
                    email = obj["email"]
            except Exception:
                pass
        return token, email
    except Exception:
        return None, None


def read_cursor_ide_token() -> Optional[str]:
    if not CURSOR_DB.is_file():
        return None
    try:
        con = sqlite3.connect(f"file:{CURSOR_DB.as_posix()}?mode=ro", uri=True)
    except Exception:
        return None
    try:
        row = con.execute(
            "SELECT value FROM ItemTable WHERE key = ? LIMIT 1", (TOKEN_KEY,)
        ).fetchone()
    finally:
        con.close()
    if not row:
        return None
    value = row[0]
    if isinstance(value, memoryview):
        value = value.tobytes()
    if isinstance(value, bytes):
        if len(value) >= 2 and len(value) % 2 == 0 and value[1:2] == b"\x00":
            try:
                return value.decode("utf-16-le")
            except Exception:
                pass
        try:
            return value.decode("utf-8")
        except Exception:
            return None
    if isinstance(value, str):
        return value
    return None


def build_cookie(token: str) -> Optional[str]:
    claims = jwt_claims(token)
    if not claims:
        return None
    sub = claims.get("sub")
    exp = claims.get("exp")
    if not isinstance(sub, str) or not sub:
        return None
    if isinstance(exp, (int, float)) and exp <= time.time() + 60:
        return None
    account = sub.split("|")[-1]
    if not account:
        return None
    return f"WorkosCursorSessionToken={account}%3A%3A{token}"


def fetch_sand(cookie: str) -> dict:
    req = urllib.request.Request(
        ENDPOINT,
        data=b"{}",
        method="POST",
        headers={
            "Cookie": cookie,
            "Accept": "application/json",
            "Content-Type": "application/json",
            "Origin": "https://cursor.com",
            "User-Agent": "QuotaDock-GrokBot-Sync/1.0",
        },
    )

    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: N802
            return None

    opener = urllib.request.build_opener(NoRedirect)
    with opener.open(req, timeout=20) as resp:
        return json.loads(resp.read().decode("utf-8"))


def remaining_from_reply(reply: dict) -> Tuple[Optional[int], Optional[str], Optional[str]]:
    if reply.get("usesPooledEnterpriseAllowance") is True:
        return None, None, "enterprise pooled allowance (no personal share)"
    if reply.get("includedLimitZero") is True:
        return None, None, "Grok Bot not included on this plan"
    if reply.get("hasNonZeroIncludedLimit") is not True:
        said = any(
            reply.get(k) is not None
            for k in (
                "usesPooledEnterpriseAllowance",
                "includedLimitZero",
                "hasNonZeroIncludedLimit",
            )
        )
        if said:
            return None, None, "Grok Bot not included on this plan"
        return None, None, "unreadable sand usage reply"

    used = reply.get("usagePercent")
    if used is None:
        return None, None, "usagePercent missing"
    try:
        used_f = float(used)
    except (TypeError, ValueError):
        return None, None, "usagePercent not a number"
    remaining = int(round(max(0.0, min(100.0, 100.0 - used_f))))
    reset = reply.get("nextResetTimestampUtc")
    reset_text = None
    if isinstance(reset, str) and reset.strip():
        try:
            dt = datetime.fromisoformat(reset.strip().replace("Z", "+00:00"))
            reset_text = dt.astimezone().strftime("%m-%d %H:%M 重置")
        except Exception:
            reset_text = reset.strip()
    return remaining, reset_text, None


def previous_windows(prev: dict) -> list:
    windows = prev.get("windows")
    return windows if isinstance(windows, list) else []


def write_success(
    remaining: int, reset_text: Optional[str], plan: Optional[str], source: str
) -> None:
    now = iso_now()
    badge = (plan or "Grok Bot").strip() or "Grok Bot"
    payload = {
        "title": "Grok Bot",
        "badge": badge,
        "status": f"已同步 {datetime.now().strftime('%H:%M')}",
        "updatedAt": now,
        "lastSuccessAt": now,
        "lastAttemptAt": now,
        "syncStatus": "success",
        "lastError": None,
        "source": source,
        "windows": [
            {
                "label": "周额度",
                "remainingPercent": remaining,
                "resetText": reset_text or "重置时间未知（接口未返回）",
            }
        ],
    }
    atomic_write(OUT, payload)


def write_failure(message: str) -> None:
    prev = load_json(OUT)
    now = iso_now()
    windows = previous_windows(prev) or [
        {"label": "周额度", "remainingPercent": None, "resetText": "等待同步"}
    ]
    payload = {
        "title": prev.get("title") or "Grok Bot",
        "badge": prev.get("badge") or "Grok Bot",
        "status": "同步失败",
        "updatedAt": prev.get("updatedAt") or prev.get("lastSuccessAt"),
        "lastSuccessAt": prev.get("lastSuccessAt"),
        "lastAttemptAt": now,
        "syncStatus": "error",
        "lastError": message[:200],
        "windows": windows,
    }
    atomic_write(OUT, payload)


def resolve_token() -> Tuple[Optional[str], str]:
    token, _email = read_grok_bot_token()
    if token:
        return token, "grok-bot-app"
    token = read_cursor_ide_token()
    if token:
        return token, "cursor-ide"
    return None, "none"


def sync_once() -> int:
    if AESGCM is None:
        write_failure("缺少 cryptography 包，请: python -m pip install cryptography")
        return 1
    token, source = resolve_token()
    if not token:
        write_failure("未找到 Grok Bot / Cursor 登录态（请先登录 Grok Bot 应用）")
        return 2
    cookie = build_cookie(token)
    if not cookie:
        write_failure("登录已过期（请重新打开 Grok Bot 或 Cursor 登录）")
        return 3
    try:
        reply = fetch_sand(cookie)
    except urllib.error.HTTPError as exc:
        if exc.code in (401, 403):
            write_failure(f"HTTP {exc.code} · session expired")
        elif exc.code == 429:
            write_failure("HTTP 429 · rate limited")
        else:
            write_failure(f"HTTP {exc.code}")
        return 4
    except Exception:
        write_failure("request failed")
        return 5

    if not isinstance(reply, dict):
        write_failure("unreadable sand usage reply")
        return 6

    remaining, reset_text, err = remaining_from_reply(reply)
    if err:
        write_failure(err)
        return 7
    assert remaining is not None
    plan = reply.get("grokPlanLabel") or reply.get("includedUsageSuperGrokPlan")
    if not isinstance(plan, str):
        plan = None
    write_success(remaining, reset_text, plan, source)
    return 0


def acquire_lock():
    LOCK.parent.mkdir(parents=True, exist_ok=True)
    handle = LOCK.open("a+", encoding="utf-8")
    try:
        import msvcrt

        handle.seek(0)
        handle.write(str(os.getpid()))
        handle.flush()
        handle.seek(0)
        msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
        return handle
    except Exception:
        handle.close()
        return None


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Sync Grok Bot quota for QuotaDock")
    parser.add_argument("--sync-once", action="store_true")
    parser.add_argument("--sync-only", action="store_true")
    args = parser.parse_args(argv)

    if args.sync_only:
        lock = acquire_lock()
        if lock is None:
            return 0
        try:
            while True:
                sync_once()
                time.sleep(POLL_SEC)
        finally:
            try:
                lock.close()
            except Exception:
                pass
        return 0

    return sync_once()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
