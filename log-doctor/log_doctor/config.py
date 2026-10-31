"""All configuration comes from environment variables (12-factor style)."""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field


class ConfigError(ValueError):
    pass


def _int(name: str, default: int, minimum: int = 1) -> int:
    raw = os.getenv(name)
    if raw is None or raw == "":
        return default
    try:
        value = int(raw)
    except ValueError as exc:
        raise ConfigError(f"{name} must be an integer, got {raw!r}") from exc
    if value < minimum:
        raise ConfigError(f"{name} must be >= {minimum}, got {value}")
    return value


def _bool(name: str, default: bool = False) -> bool:
    raw = os.getenv(name)
    if raw is None or raw == "":
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def _list(name: str, default: str) -> list[str]:
    return [item.strip() for item in os.getenv(name, default).split(",") if item.strip()]


@dataclass(frozen=True)
class Config:
    # OpenSearch
    opensearch_host: str
    aws_region: str
    index_pattern: str = "app-logs-*"
    lookback_minutes: int = 15
    error_levels: list[str] = field(default_factory=lambda: ["ERROR", "CRITICAL", "FATAL"])
    level_field: str = "level.keyword"
    service_field: str = "service.keyword"
    message_field: str = "message.keyword"
    timestamp_field: str = "@timestamp"

    # Aggregation / truncation limits (these bound the LLM token cost)
    max_services: int = 10
    max_messages_per_service: int = 5
    samples_per_message: int = 2
    max_message_chars: int = 300
    max_stack_lines: int = 12
    max_sample_chars: int = 1200
    max_prompt_chars: int = 16000

    # Bedrock
    model_id: str = ""
    max_output_tokens: int = 2000
    additional_model_fields: dict | None = None

    # Slack
    slack_webhook_url: str = ""

    # Behaviour
    dry_run: bool = False
    skip_llm: bool = False
    log_level: str = "INFO"

    @classmethod
    def from_env(cls, *, dry_run: bool = False, skip_llm: bool = False, lookback_minutes: int | None = None) -> "Config":
        dry_run = dry_run or _bool("DRY_RUN")
        skip_llm = skip_llm or _bool("SKIP_LLM")

        host = os.getenv("OPENSEARCH_HOST", "").strip()
        host = host.removeprefix("https://").removeprefix("http://").rstrip("/")
        region = os.getenv("AWS_REGION") or os.getenv("AWS_DEFAULT_REGION") or ""
        model_id = os.getenv("MODEL_ID", "").strip()
        webhook = os.getenv("SLACK_WEBHOOK_URL", "").strip()

        missing = [n for n, v in (("OPENSEARCH_HOST", host), ("AWS_REGION", region)) if not v]
        if not skip_llm and not model_id:
            missing.append("MODEL_ID")
        if not dry_run and not webhook:
            missing.append("SLACK_WEBHOOK_URL")
        if missing:
            raise ConfigError(f"Missing required environment variables: {', '.join(missing)}")

        if webhook and not webhook.startswith("https://hooks.slack.com/"):
            raise ConfigError("SLACK_WEBHOOK_URL must start with https://hooks.slack.com/")

        extra_raw = os.getenv("BEDROCK_ADDITIONAL_FIELDS", "").strip()
        try:
            extra = json.loads(extra_raw) if extra_raw else None
        except json.JSONDecodeError as exc:
            raise ConfigError(f"BEDROCK_ADDITIONAL_FIELDS is not valid JSON: {exc}") from exc

        return cls(
            opensearch_host=host,
            aws_region=region,
            index_pattern=os.getenv("OPENSEARCH_INDEX_PATTERN", "app-logs-*"),
            lookback_minutes=lookback_minutes or _int("LOOKBACK_MINUTES", 15),
            error_levels=_list("ERROR_LEVELS", "ERROR,CRITICAL,FATAL"),
            level_field=os.getenv("LEVEL_FIELD", "level.keyword"),
            service_field=os.getenv("SERVICE_FIELD", "service.keyword"),
            message_field=os.getenv("MESSAGE_FIELD", "message.keyword"),
            timestamp_field=os.getenv("TIMESTAMP_FIELD", "@timestamp"),
            max_services=_int("MAX_SERVICES", 10),
            max_messages_per_service=_int("MAX_MESSAGES_PER_SERVICE", 5),
            samples_per_message=_int("SAMPLES_PER_MESSAGE", 2, minimum=0),
            max_message_chars=_int("MAX_MESSAGE_CHARS", 300),
            max_stack_lines=_int("MAX_STACK_LINES", 12, minimum=0),
            max_sample_chars=_int("MAX_SAMPLE_CHARS", 1200),
            max_prompt_chars=_int("MAX_PROMPT_CHARS", 16000, minimum=1000),
            model_id=model_id,
            max_output_tokens=_int("MAX_OUTPUT_TOKENS", 2000, minimum=100),
            additional_model_fields=extra,
            slack_webhook_url=webhook,
            dry_run=dry_run,
            skip_llm=skip_llm,
            log_level=os.getenv("LOG_LEVEL", "INFO").upper(),
        )
