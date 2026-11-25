#!/usr/bin/env python3
"""GitHub Issue Monitor & Telegram Notifier for Remoter.

Stdlib-only helper CLI used by the Antigravity scheduled automation to:
1. Check for newly opened GitHub issues not yet processed.
2. Track processed issues in ~/.config/remoter-issue-monitor/state.json.
3. Push structured notifications to Telegram Bot API (with HTML escaping and
   local fallback queue if Telegram credentials are not yet configured).
"""

from __future__ import annotations

import argparse
import html
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

CONFIG_DIR = Path.home() / ".config" / "remoter-issue-monitor"
CONFIG_FILE = CONFIG_DIR / "config.json"
STATE_FILE = CONFIG_DIR / "state.json"
PENDING_NOTIFY_FILE = CONFIG_DIR / "pending_notifications.jsonl"

DEFAULT_CONFIG: Dict[str, Any] = {
    "repo": "ricklxf/Remoter",
    "telegram_bot_token": "",
    "telegram_chat_id": "",
    "base_branch": "main",
    "ignore_labels": ["wontfix", "invalid", "duplicate"],
}


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def ensure_config_dir() -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)


def load_config() -> Dict[str, Any]:
    cfg = dict(DEFAULT_CONFIG)
    if CONFIG_FILE.exists():
        try:
            data = json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                cfg.update(data)
        except json.JSONDecodeError as exc:
            print(f"Warning: invalid config file {CONFIG_FILE}: {exc}", file=sys.stderr)

    # Environment variable overrides
    if os.environ.get("ISSUE_MONITOR_REPO"):
        cfg["repo"] = os.environ["ISSUE_MONITOR_REPO"]
    if os.environ.get("TELEGRAM_BOT_TOKEN"):
        cfg["telegram_bot_token"] = os.environ["TELEGRAM_BOT_TOKEN"]
    if os.environ.get("TELEGRAM_CHAT_ID"):
        cfg["telegram_chat_id"] = os.environ["TELEGRAM_CHAT_ID"]
    return cfg


def save_config(cfg: Dict[str, Any]) -> None:
    ensure_config_dir()
    CONFIG_FILE.write_text(
        json.dumps(cfg, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    try:
        os.chmod(CONFIG_FILE, 0o600)
    except OSError:
        pass


def load_state() -> Dict[str, Any]:
    if STATE_FILE.exists():
        try:
            data = json.loads(STATE_FILE.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                data.setdefault("processed_issues", {})
                return data
        except json.JSONDecodeError as exc:
            print(f"Warning: invalid state file {STATE_FILE}: {exc}", file=sys.stderr)
    return {"processed_issues": {}, "last_checked_at": None}


def save_state(state: Dict[str, Any]) -> None:
    ensure_config_dir()
    STATE_FILE.write_text(
        json.dumps(state, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def fetch_open_issues(repo: str, limit: int = 30, retries: int = 3) -> List[Dict[str, Any]]:
    cmd = [
        "gh",
        "issue",
        "list",
        "--repo",
        repo,
        "--state",
        "open",
        "--limit",
        str(limit),
        "--json",
        "number,title,body,author,labels,createdAt,updatedAt,url,comments",
    ]
    last_err = ""
    for attempt in range(1, retries + 1):
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
        if proc.returncode == 0:
            raw = proc.stdout.strip()
            if not raw:
                return []
            issues = json.loads(raw)
            if not isinstance(issues, list):
                return []
            return issues
        last_err = f"gh issue list failed (exit {proc.returncode}): {proc.stderr.strip()}"
        if attempt < retries:
            time.sleep(2 * attempt)
    raise RuntimeError(last_err)


def filter_new_issues(
    issues: List[Dict[str, Any]],
    processed: Dict[str, Any],
    ignore_labels: List[str],
    include_processed: bool = False,
) -> List[Dict[str, Any]]:
    ignore_set = {lbl.lower() for lbl in ignore_labels}
    result: List[Dict[str, Any]] = []
    for issue in issues:
        num_str = str(issue.get("number"))
        if not include_processed and num_str in processed:
            continue
        labels = [
            (lbl.get("name") or "").lower()
            for lbl in (issue.get("labels") or [])
            if isinstance(lbl, dict)
        ]
        if any(lbl in ignore_set for lbl in labels):
            continue
        result.append(issue)
    # Sort oldest first so earlier issues are triaged first
    result.sort(key=lambda item: int(item.get("number", 0)))
    return result


def build_telegram_html(
    notify_type: str,
    repo: str,
    issue_number: Optional[int],
    title: str,
    url: str,
    summary: str,
    pr_url: str = "",
) -> str:
    badge_map = {
        "feature": "💡 <b>[新需求 / 功能建议]</b>",
        "bug-fixed": "✅ <b>[Bug 已自动修复并提 PR]</b>",
        "bug-failed": "⚠️ <b>[Bug 自动修复受阻，需人工介入]</b>",
        "needs-info": "❓ <b>[Issue 信息不足，已补充询问]</b>",
        "test": "🔔 <b>[Issue 监控测试通知]</b>",
    }
    header = badge_map.get(notify_type, "📌 <b>[Issue 通知]</b>")

    lines = [header, f"仓库：<code>{html.escape(repo)}</code>"]
    if issue_number is not None:
        safe_title = html.escape(title or f"Issue #{issue_number}")
        if url:
            lines.append(
                f'Issue：<a href="{html.escape(url, quote=True)}">#{issue_number} {safe_title}</a>'
            )
        else:
            lines.append(f"Issue：#{issue_number} {safe_title}")
    elif title:
        lines.append(f"标题：{html.escape(title)}")

    if pr_url:
        lines.append(f'修复 PR：<a href="{html.escape(pr_url, quote=True)}">{html.escape(pr_url)}</a>')

    if summary:
        lines.append("")
        lines.append(f"<b>摘要</b>：\n{html.escape(summary.strip())}")

    return "\n".join(lines)


def send_telegram_message(
    token: str,
    chat_id: str,
    html_text: str,
    retries: int = 5,
    delay: float = 3.0,
) -> Dict[str, Any]:
    api_url = f"https://api.telegram.org/bot{token}/sendMessage"
    payload = {
        "chat_id": chat_id,
        "text": html_text,
        "parse_mode": "HTML",
        "disable_web_page_preview": True,
    }
    data = json.dumps(payload).encode("utf-8")
    last_err = ""
    for attempt in range(1, retries + 1):
        req = urllib.request.Request(
            api_url,
            data=data,
            headers={"Content-Type": "application/json", "Connection": "close"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                body = resp.read().decode("utf-8")
                return json.loads(body)
        except urllib.error.HTTPError as exc:
            err_body = exc.read().decode("utf-8", errors="replace")
            last_err = f"Telegram API HTTP {exc.code}: {err_body}"
            # Do not retry 4xx client errors (except 429)
            if 400 <= exc.code < 500 and exc.code != 429:
                raise RuntimeError(last_err) from None
        except Exception as exc:
            # Never leak bot token from exception URLs
            last_err = f"Telegram API error ({type(exc).__name__}): {exc}".replace(token, "<REDACTED>")
        if attempt < retries:
            time.sleep(delay)
    raise RuntimeError(f"Telegram API failed after {retries} attempts: {last_err}")


def queue_pending_notification(record: Dict[str, Any]) -> None:
    ensure_config_dir()
    with PENDING_NOTIFY_FILE.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(record, ensure_ascii=False) + "\n")


def cmd_init(args: argparse.Namespace) -> int:
    cfg = load_config()
    if args.repo:
        cfg["repo"] = args.repo
    if args.bot_token is not None:
        cfg["telegram_bot_token"] = args.bot_token.strip()
    if args.chat_id is not None:
        cfg["telegram_chat_id"] = args.chat_id.strip()
    if args.base_branch:
        cfg["base_branch"] = args.base_branch.strip()
    save_config(cfg)

    configured = bool(cfg.get("telegram_bot_token") and cfg.get("telegram_chat_id"))
    print(
        json.dumps(
            {
                "config_file": str(CONFIG_FILE),
                "repo": cfg["repo"],
                "base_branch": cfg["base_branch"],
                "telegram_configured": configured,
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


def cmd_check(args: argparse.Namespace) -> int:
    cfg = load_config()
    repo = args.repo or cfg["repo"]
    state = load_state()

    issues = fetch_open_issues(repo, limit=args.limit)
    new_issues = filter_new_issues(
        issues=issues,
        processed=state.get("processed_issues", {}),
        ignore_labels=cfg.get("ignore_labels", []),
        include_processed=args.include_processed,
    )

    state["last_checked_at"] = now_iso()
    save_state(state)

    output = {
        "repo": repo,
        "checked_at": state["last_checked_at"],
        "total_open": len(issues),
        "count": len(new_issues),
        "new_issues": new_issues,
    }
    print(json.dumps(output, ensure_ascii=False, indent=2))
    return 0


def cmd_notify(args: argparse.Namespace) -> int:
    cfg = load_config()
    repo = args.repo or cfg["repo"]
    html_text = build_telegram_html(
        notify_type=args.type,
        repo=repo,
        issue_number=args.issue,
        title=args.title or "",
        url=args.url or "",
        summary=args.summary or "",
        pr_url=args.pr_url or "",
    )

    if args.dry_run:
        print(
            json.dumps(
                {
                    "dry_run": True,
                    "telegram_configured": bool(
                        cfg.get("telegram_bot_token") and cfg.get("telegram_chat_id")
                    ),
                    "html": html_text,
                },
                ensure_ascii=False,
                indent=2,
            )
        )
        return 0

    token = cfg.get("telegram_bot_token", "").strip()
    chat_id = str(cfg.get("telegram_chat_id", "")).strip()
    if not token or not chat_id:
        record = {
            "queued_at": now_iso(),
            "type": args.type,
            "repo": repo,
            "issue": args.issue,
            "title": args.title or "",
            "url": args.url or "",
            "pr_url": args.pr_url or "",
            "summary": args.summary or "",
            "html": html_text,
        }
        queue_pending_notification(record)
        print(
            json.dumps(
                {
                    "sent": False,
                    "queued": True,
                    "reason": "Telegram bot_token or chat_id not configured",
                    "pending_file": str(PENDING_NOTIFY_FILE),
                },
                ensure_ascii=False,
                indent=2,
            )
        )
        return 0

    resp = send_telegram_message(token, chat_id, html_text)
    print(json.dumps({"sent": True, "response": resp}, ensure_ascii=False, indent=2))
    return 0


def cmd_mark(args: argparse.Namespace) -> int:
    state = load_state()
    processed = state.setdefault("processed_issues", {})
    key = str(args.issue)
    processed[key] = {
        "issue": args.issue,
        "status": args.status,
        "title": args.title or "",
        "summary": args.summary or "",
        "pr_url": args.pr_url or "",
        "updated_at": now_iso(),
    }
    save_state(state)
    print(json.dumps({"marked": True, "record": processed[key]}, ensure_ascii=False, indent=2))
    return 0


def cmd_status(_args: argparse.Namespace) -> int:
    cfg = load_config()
    state = load_state()
    token = cfg.get("telegram_bot_token", "")
    masked = f"{token[:6]}...{token[-4:]}" if len(token) > 12 else ("<set>" if token else "<not set>")
    pending_count = 0
    if PENDING_NOTIFY_FILE.exists():
        pending_count = sum(
            1 for line in PENDING_NOTIFY_FILE.read_text(encoding="utf-8").splitlines() if line.strip()
        )
    print(
        json.dumps(
            {
                "config_file": str(CONFIG_FILE),
                "state_file": str(STATE_FILE),
                "repo": cfg.get("repo"),
                "base_branch": cfg.get("base_branch"),
                "telegram_bot_token": masked,
                "telegram_chat_id": cfg.get("telegram_chat_id") or "<not set>",
                "last_checked_at": state.get("last_checked_at"),
                "processed_count": len(state.get("processed_issues", {})),
                "pending_notifications": pending_count,
                "processed_issues": state.get("processed_issues", {}),
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="GitHub Issue Monitor & Telegram Notifier"
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_init = sub.add_parser("init", help="Initialize or update local config")
    p_init.add_argument("--repo", help="GitHub repo (owner/name)")
    p_init.add_argument("--bot-token", dest="bot_token", help="Telegram Bot Token")
    p_init.add_argument("--chat-id", dest="chat_id", help="Telegram Chat ID")
    p_init.add_argument("--base-branch", dest="base_branch", help="Default base branch")
    p_init.set_defaults(func=cmd_init)

    p_check = sub.add_parser("check", help="Fetch open issues not yet processed")
    p_check.add_argument("--repo", help="Override GitHub repo (owner/name)")
    p_check.add_argument("--limit", type=int, default=30, help="Max open issues to fetch")
    p_check.add_argument(
        "--include-processed",
        action="store_true",
        help="Include already processed issues",
    )
    p_check.set_defaults(func=cmd_check)

    p_notify = sub.add_parser("notify", help="Send Telegram notification")
    p_notify.add_argument(
        "--type",
        required=True,
        choices=["feature", "bug-fixed", "bug-failed", "needs-info", "test"],
        help="Notification type",
    )
    p_notify.add_argument("--repo", help="Override GitHub repo")
    p_notify.add_argument("--issue", type=int, help="GitHub Issue number")
    p_notify.add_argument("--title", default="", help="Issue title")
    p_notify.add_argument("--url", default="", help="Issue URL")
    p_notify.add_argument("--pr-url", dest="pr_url", default="", help="PR URL")
    p_notify.add_argument("--summary", default="", help="Notification summary")
    p_notify.add_argument("--dry-run", action="store_true", help="Print payload without sending")
    p_notify.set_defaults(func=cmd_notify)

    p_mark = sub.add_parser("mark", help="Mark an issue as processed in local state")
    p_mark.add_argument("--issue", type=int, required=True, help="Issue number")
    p_mark.add_argument(
        "--status",
        required=True,
        choices=["bug_fixed_pr", "feature_notified", "needs_info", "not_a_bug", "fix_failed"],
        help="Processing outcome",
    )
    p_mark.add_argument("--title", default="", help="Issue title")
    p_mark.add_argument("--summary", default="", help="Brief summary")
    p_mark.add_argument("--pr-url", dest="pr_url", default="", help="PR URL if created")
    p_mark.set_defaults(func=cmd_mark)

    p_status = sub.add_parser("status", help="Show current configuration and state")
    p_status.set_defaults(func=cmd_status)

    return parser


def main(argv: Optional[List[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
