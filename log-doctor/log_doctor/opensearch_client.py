"""Query OpenSearch for recent ERROR logs, aggregated per service and message.

Auth is SigV4 using whatever credentials boto3 finds - in the cluster that's
the IRSA web-identity token for the log-doctor ServiceAccount. The IAM policy
only allows GET/POST on <index-pattern>/_search, so this module never does
anything else.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Any

import boto3
from opensearchpy import AWSV4SignerAuth, OpenSearch, RequestsHttpConnection

from .config import Config

log = logging.getLogger(__name__)

SAMPLE_SOURCE_FIELDS = [
    "@timestamp",
    "timestamp",
    "level",
    "service",
    "message",
    "trace_id",
    "error.type",
    "error.message",
    "error.stack_trace",
    "kubernetes.pod_name",
    "kubernetes.namespace_name",
    "kubernetes.container_name",
]


@dataclass
class MessageGroup:
    message: str
    count: int
    first_seen: str | None
    last_seen: str | None
    samples: list[dict[str, Any]] = field(default_factory=list)


@dataclass
class ServiceErrors:
    service: str
    total: int
    groups: list[MessageGroup] = field(default_factory=list)
    other_messages: int = 0  # errors whose message fell outside the top-N


@dataclass
class ErrorReport:
    window_minutes: int
    total_errors: int
    services: list[ServiceErrors] = field(default_factory=list)
    other_services_errors: int = 0  # errors from services outside the top-N


def build_client(cfg: Config) -> OpenSearch:
    credentials = boto3.Session(region_name=cfg.aws_region).get_credentials()
    if credentials is None:
        raise RuntimeError("No AWS credentials found (is the IRSA annotation on the ServiceAccount?)")
    auth = AWSV4SignerAuth(credentials, cfg.aws_region, "es")
    return OpenSearch(
        hosts=[{"host": cfg.opensearch_host, "port": 443}],
        http_auth=auth,
        use_ssl=True,
        verify_certs=True,
        connection_class=RequestsHttpConnection,
        timeout=30,
        max_retries=2,
        retry_on_timeout=True,
    )


def build_query(cfg: Config) -> dict[str, Any]:
    return {
        "size": 0,
        "track_total_hits": True,
        "query": {
            "bool": {
                "filter": [
                    {"terms": {cfg.level_field: cfg.error_levels}},
                    {"range": {cfg.timestamp_field: {"gte": f"now-{cfg.lookback_minutes}m", "lte": "now"}}},
                ]
            }
        },
        "aggs": {
            "services": {
                "terms": {"field": cfg.service_field, "size": cfg.max_services, "missing": "(unknown)"},
                "aggs": {
                    "messages": {
                        "terms": {"field": cfg.message_field, "size": cfg.max_messages_per_service},
                        "aggs": {
                            "first_seen": {"min": {"field": cfg.timestamp_field}},
                            "last_seen": {"max": {"field": cfg.timestamp_field}},
                            "samples": {
                                "top_hits": {
                                    "size": cfg.samples_per_message,
                                    "sort": [{cfg.timestamp_field: {"order": "desc"}}],
                                    "_source": {"includes": SAMPLE_SOURCE_FIELDS},
                                }
                            },
                        },
                    }
                },
            }
        },
    }


def parse_response(cfg: Config, resp: dict[str, Any]) -> ErrorReport:
    total = resp.get("hits", {}).get("total", {})
    total_errors = total.get("value", 0) if isinstance(total, dict) else int(total or 0)

    services_agg = resp.get("aggregations", {}).get("services", {})
    report = ErrorReport(
        window_minutes=cfg.lookback_minutes,
        total_errors=total_errors,
        other_services_errors=services_agg.get("sum_other_doc_count", 0),
    )

    for svc_bucket in services_agg.get("buckets", []):
        msgs_agg = svc_bucket.get("messages", {})
        svc = ServiceErrors(
            service=str(svc_bucket["key"]),
            total=svc_bucket["doc_count"],
            other_messages=msgs_agg.get("sum_other_doc_count", 0),
        )
        for msg_bucket in msgs_agg.get("buckets", []):
            svc.groups.append(
                MessageGroup(
                    message=str(msg_bucket["key"]),
                    count=msg_bucket["doc_count"],
                    first_seen=msg_bucket.get("first_seen", {}).get("value_as_string"),
                    last_seen=msg_bucket.get("last_seen", {}).get("value_as_string"),
                    samples=[h.get("_source", {}) for h in msg_bucket.get("samples", {}).get("hits", {}).get("hits", [])],
                )
            )
        report.services.append(svc)
    return report


def fetch_error_report(cfg: Config, client: OpenSearch | None = None) -> ErrorReport:
    client = client or build_client(cfg)
    query = build_query(cfg)
    log.info(
        "Querying OpenSearch",
        extra={"fields": {"index": cfg.index_pattern, "lookback_minutes": cfg.lookback_minutes}},
    )
    resp = client.search(index=cfg.index_pattern, body=query, params={"ignore_unavailable": "true", "allow_no_indices": "true"})
    report = parse_response(cfg, resp)
    log.info(
        "OpenSearch query complete",
        extra={"fields": {"total_errors": report.total_errors, "services": len(report.services), "took_ms": resp.get("took")}},
    )
    return report
