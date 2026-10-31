"""Tiny orders microservice that emits structured JSON logs to stdout.

Every log line is a single JSON object with: timestamp, level, service,
message, trace_id (+ an "error" object for exceptions). Fluentd parses these
lines and ships them to OpenSearch.

Endpoints:
  GET  /health
  GET  /orders                         normal INFO logs
  POST /orders                         normal INFO logs
  GET  /simulate-error?type=db|timeout|null&count=N
                                       realistic ERROR logs with stack traces
"""

from __future__ import annotations

import contextvars
import json
import logging
import os
import random
import traceback
import uuid
from datetime import datetime, timezone

import uvicorn
from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.responses import JSONResponse

SERVICE_NAME = os.getenv("SERVICE_NAME", "orders-api")
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()
PORT = int(os.getenv("PORT", "8080"))

trace_id_var: contextvars.ContextVar[str] = contextvars.ContextVar("trace_id", default="-")


# ---------------------------------------------------------------------------
# Structured JSON logging
# ---------------------------------------------------------------------------
class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        entry = {
            "timestamp": datetime.fromtimestamp(record.created, tz=timezone.utc).isoformat(timespec="milliseconds"),
            "level": record.levelname,
            "service": SERVICE_NAME,
            "message": record.getMessage(),
            "trace_id": trace_id_var.get(),
            "logger": record.name,
        }
        if record.exc_info:
            exc_type, exc_value, _ = record.exc_info
            entry["error"] = {
                "type": exc_type.__name__ if exc_type else "Exception",
                "message": str(exc_value),
                "stack_trace": "".join(traceback.format_exception(*record.exc_info)),
            }
        extra = getattr(record, "fields", None)
        if isinstance(extra, dict):
            entry.update(extra)
        return json.dumps(entry, default=str)


LOGGING_CONFIG = {
    "version": 1,
    "disable_existing_loggers": False,
    "formatters": {"json": {"()": JsonFormatter}},
    "handlers": {
        "stdout": {"class": "logging.StreamHandler", "formatter": "json", "stream": "ext://sys.stdout"},
    },
    "root": {"handlers": ["stdout"], "level": LOG_LEVEL},
    "loggers": {
        # Route uvicorn's own logs through the JSON formatter too.
        "uvicorn": {"handlers": ["stdout"], "level": LOG_LEVEL, "propagate": False},
        "uvicorn.error": {"handlers": ["stdout"], "level": LOG_LEVEL, "propagate": False},
        "uvicorn.access": {"handlers": ["stdout"], "level": "WARNING", "propagate": False},
    },
}

log = logging.getLogger(SERVICE_NAME)
app = FastAPI(title=SERVICE_NAME)


@app.middleware("http")
async def trace_middleware(request: Request, call_next):
    trace_id = request.headers.get("x-trace-id") or uuid.uuid4().hex
    token = trace_id_var.set(trace_id)
    try:
        response = await call_next(request)
        response.headers["x-trace-id"] = trace_id
        return response
    finally:
        trace_id_var.reset(token)


# ---------------------------------------------------------------------------
# Fake domain layer - just deep enough to produce realistic stack traces
# ---------------------------------------------------------------------------
class DatabaseConnectionError(Exception):
    """Mimics psycopg's OperationalError for a saturated Postgres."""


class UpstreamTimeoutError(TimeoutError):
    """Mimics an HTTP client read timeout."""


class ConnectionPool:
    def __init__(self, host: str, max_size: int) -> None:
        self.host = host
        self.max_size = max_size

    def acquire(self, timeout_s: float = 2.0):
        raise DatabaseConnectionError(
            f'connection to server at "{self.host}" (10.40.3.21), port 5432 failed: '
            "FATAL:  remaining connection slots are reserved for non-replication superuser connections"
        )


class OrderRepository:
    def __init__(self, pool: ConnectionPool) -> None:
        self.pool = pool

    def get_order(self, order_id: str) -> dict:
        conn = self.pool.acquire(timeout_s=2.0)
        return conn.execute("SELECT * FROM orders WHERE id = %s", (order_id,))


class PaymentClient:
    base_url = "http://payment-gateway.payments.svc.cluster.local:8080"

    def authorize(self, order_id: str, amount: float, timeout_s: float = 5.0) -> dict:
        return self._post("/v1/authorize", {"order_id": order_id, "amount": amount}, timeout_s)

    def _post(self, path: str, body: dict, timeout_s: float) -> dict:
        raise UpstreamTimeoutError(f"POST {self.base_url}{path} timed out after {timeout_s}s (read timeout)")


class CustomerService:
    _customers = {"c-1001": {"email": "alice@example.com", "tier": "gold"}}

    def find(self, customer_id: str) -> dict | None:
        return self._customers.get(customer_id)


def build_confirmation_email(customer_id: str) -> str:
    customer = CustomerService().find(customer_id)
    return f"To: {customer['email']}"  # customer is None for unknown IDs -> TypeError


repo = OrderRepository(ConnectionPool(host="orders-db.internal", max_size=20))
payments = PaymentClient()


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------
@app.get("/health")
def health() -> dict:
    return {"status": "ok", "service": SERVICE_NAME}


@app.get("/orders")
def list_orders() -> dict:
    orders = [
        {"id": f"o-{random.randint(10000, 99999)}", "amount": round(random.uniform(5, 500), 2), "status": "PAID"}
        for _ in range(random.randint(1, 5))
    ]
    log.info("Fetched orders", extra={"fields": {"order_count": len(orders)}})
    return {"orders": orders}


@app.post("/orders")
def create_order() -> dict:
    order_id = f"o-{random.randint(10000, 99999)}"
    log.info("Order created", extra={"fields": {"order_id": order_id}})
    return {"id": order_id, "status": "PENDING"}


ERROR_SCENARIOS = {
    # type: (stable log message used for aggregation, callable that raises)
    "db": ("Failed to fetch order from database", lambda: repo.get_order(f"o-{random.randint(10000, 99999)}")),
    "timeout": ("Payment authorization failed: upstream timeout", lambda: payments.authorize("o-42", 129.99)),
    "null": ("Unhandled error building order confirmation", lambda: build_confirmation_email("c-9999")),
}


@app.get("/simulate-error")
def simulate_error(
    type: str = Query(..., pattern="^(db|timeout|null)$", description="db | timeout | null"),
    count: int = Query(1, ge=1, le=50, description="How many ERROR log lines to emit"),
):
    message, action = ERROR_SCENARIOS[type]
    for _ in range(count):
        try:
            action()
        except Exception:  # noqa: BLE001 - we want the full stack trace in the log
            log.exception(message, extra={"fields": {"error_scenario": type}})
    return JSONResponse(status_code=500, content={"error": message, "emitted": count, "trace_id": trace_id_var.get()})


@app.exception_handler(HTTPException)
async def http_exception_handler(request: Request, exc: HTTPException):
    log.warning("HTTP error", extra={"fields": {"status_code": exc.status_code, "path": request.url.path}})
    return JSONResponse(status_code=exc.status_code, content={"detail": exc.detail})


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=PORT, log_config=LOGGING_CONFIG, access_log=False)
