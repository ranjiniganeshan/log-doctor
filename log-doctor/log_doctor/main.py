"""Entry point: fetch -> summarise -> post.

Exit codes: 0 = success (including "no errors, nothing posted"),
            1 = failure (config, OpenSearch, Bedrock or Slack error).

Usage:
  python -m log_doctor.main              # normal run (CronJob)
  python -m log_doctor.main --dry-run    # call Bedrock, print the Slack payload instead of posting
  python -m log_doctor.main --dry-run --skip-llm   # just show what would be sent to the model
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
from datetime import datetime, timezone

from . import __version__, slack
from .config import Config, ConfigError
from .opensearch_client import fetch_error_report
from .summarizer import build_prompt, fallback_digest, summarize

log = logging.getLogger("log_doctor")


class JsonFormatter(logging.Formatter):
    """Same log shape as the sample app, so Log Doctor's own logs are searchable too."""

    def format(self, record: logging.LogRecord) -> str:
        entry = {
            "timestamp": datetime.fromtimestamp(record.created, tz=timezone.utc).isoformat(timespec="milliseconds"),
            "level": record.levelname,
            "service": "log-doctor",
            "message": record.getMessage(),
            "logger": record.name,
        }
        fields = getattr(record, "fields", None)
        if isinstance(fields, dict):
            entry.update(fields)
        if record.exc_info:
            entry["error"] = {"type": record.exc_info[0].__name__, "message": str(record.exc_info[1])}
        return json.dumps(entry, default=str)


def setup_logging(level: str) -> None:
    handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(level)
    # Keep third-party chatter down (and never log signed request headers).
    for noisy in ("botocore", "boto3", "urllib3", "opensearch"):
        logging.getLogger(noisy).setLevel(logging.WARNING)


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="log-doctor", description="Explain recent ERROR logs with an LLM on Amazon Bedrock.")
    parser.add_argument("--dry-run", action="store_true", help="print the Slack message instead of posting it")
    parser.add_argument("--skip-llm", action="store_true", help="don't call Bedrock; print the prompt that would be sent")
    parser.add_argument("--minutes", type=int, default=None, help="override LOOKBACK_MINUTES")
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    return parser.parse_args(argv)


def run(cfg: Config) -> int:
    report = fetch_error_report(cfg)
    if report.total_errors == 0:
        log.info("No errors in window; nothing to post", extra={"fields": {"lookback_minutes": cfg.lookback_minutes}})
        return 0

    prompt = build_prompt(cfg, report)
    log.info("Prompt built", extra={"fields": {"prompt_chars": len(prompt), "approx_tokens": len(prompt) // 4}})

    if cfg.skip_llm:
        print("===== PROMPT THAT WOULD BE SENT TO BEDROCK =====")
        print(prompt)
        return 0

    exit_code = 0
    try:
        summary = summarize(cfg, prompt)
        text = summary.text
        footer = (
            f"model `{cfg.model_id}` · {summary.input_tokens} in / {summary.output_tokens} out tokens · "
            f"index `{cfg.index_pattern}` · Log Doctor {__version__}"
        )
    except Exception:  # noqa: BLE001 - still notify Slack with a raw digest
        log.exception("Bedrock call failed; falling back to raw digest")
        text = fallback_digest(report)
        footer = f"Bedrock call failed - see log-doctor job logs · Log Doctor {__version__}"
        exit_code = 1

    payload = slack.build_payload(
        text,
        total_errors=report.total_errors,
        window_minutes=report.window_minutes,
        service_count=len(report.services),
        footer=footer,
    )

    if cfg.dry_run:
        print("===== SLACK MESSAGE (dry run, not posted) =====")
        print(text)
        print("===== RAW PAYLOAD =====")
        print(json.dumps(payload, indent=2))
        return exit_code

    slack.post(cfg.slack_webhook_url, payload)
    return exit_code


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        cfg = Config.from_env(dry_run=args.dry_run, skip_llm=args.skip_llm, lookback_minutes=args.minutes)
    except ConfigError as exc:
        setup_logging("INFO")
        log.error("Invalid configuration", extra={"fields": {"detail": str(exc)}})
        return 1

    setup_logging(cfg.log_level)
    log.info(
        "Log Doctor starting",
        extra={"fields": {"version": __version__, "dry_run": cfg.dry_run, "skip_llm": cfg.skip_llm, "lookback_minutes": cfg.lookback_minutes}},
    )
    try:
        return run(cfg)
    except Exception:  # noqa: BLE001 - top-level guard: log and exit non-zero
        log.exception("Log Doctor run failed")
        return 1


if __name__ == "__main__":
    sys.exit(main())
