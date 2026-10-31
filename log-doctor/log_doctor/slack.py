"""Post a summary to Slack through an incoming webhook, using Block Kit."""

from __future__ import annotations

import logging
import time
from typing import Any

import requests

log = logging.getLogger(__name__)

SECTION_LIMIT = 2900  # Slack's hard limit for a section's text is 3000 chars
MAX_BLOCKS = 48  # Slack allows 50 blocks per message


def _chunk(text: str, limit: int = SECTION_LIMIT) -> list[str]:
    """Split text on line boundaries into chunks no longer than limit."""
    chunks: list[str] = []
    current = ""
    for line in text.splitlines(keepends=True):
        while len(line) > limit:  # a single monster line
            if current:
                chunks.append(current)
                current = ""
            chunks.append(line[:limit])
            line = line[limit:]
        if len(current) + len(line) > limit:
            chunks.append(current)
            current = ""
        current += line
    if current.strip():
        chunks.append(current)
    return chunks


def escape(text: str) -> str:
    """Escape Slack control characters.

    The summary is derived from untrusted log content, so neutralise
    <!channel>/<!here> mentions and <url|label> links. *bold*, _italic_ and
    `code` formatting are unaffected.
    """
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def build_payload(summary_text: str, *, total_errors: int, window_minutes: int, service_count: int, footer: str) -> dict[str, Any]:
    title = f":stethoscope: Log Doctor: {total_errors} errors in {service_count} service(s), last {window_minutes} min"
    blocks: list[dict[str, Any]] = [
        {"type": "header", "text": {"type": "plain_text", "text": title[:150], "emoji": True}},
    ]
    for chunk in _chunk(escape(summary_text)):
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": chunk}})
    blocks = blocks[: MAX_BLOCKS - 2]
    blocks.append({"type": "divider"})
    blocks.append({"type": "context", "elements": [{"type": "mrkdwn", "text": footer[:3000]}]})
    # "text" is the notification / fallback text.
    return {"text": title, "blocks": blocks}


def post(webhook_url: str, payload: dict[str, Any], attempts: int = 3) -> None:
    for attempt in range(1, attempts + 1):
        try:
            resp = requests.post(webhook_url, json=payload, timeout=10)
        except requests.RequestException as exc:
            log.warning("Slack request failed", extra={"fields": {"attempt": attempt, "error": str(exc)}})
        else:
            if resp.status_code == 200:
                log.info("Posted summary to Slack")
                return
            if resp.status_code != 429 and resp.status_code < 500:
                # 4xx other than rate-limit won't fix itself (bad payload, revoked webhook...)
                raise RuntimeError(f"Slack rejected the message: HTTP {resp.status_code} {resp.text[:200]}")
            log.warning("Slack returned retryable status", extra={"fields": {"attempt": attempt, "status": resp.status_code}})
            retry_after = resp.headers.get("Retry-After")
            if retry_after and retry_after.isdigit():
                time.sleep(min(int(retry_after), 30))
                continue
        time.sleep(2**attempt)
    raise RuntimeError(f"Failed to post to Slack after {attempts} attempts")
