#!/usr/bin/env bash
# Generate a burst of normal traffic plus realistic errors on both sample
# services, through kubectl port-forward (nothing is exposed publicly).
set -euo pipefail

NS=apps
ORDERS_PORT=18080
PAYMENTS_PORT=18081

kubectl -n "${NS}" port-forward svc/orders-api "${ORDERS_PORT}:80" >/dev/null &
PF1=$!
kubectl -n "${NS}" port-forward svc/payments-api "${PAYMENTS_PORT}:80" >/dev/null &
PF2=$!
trap 'kill ${PF1} ${PF2} 2>/dev/null || true' EXIT

for port in "${ORDERS_PORT}" "${PAYMENTS_PORT}"; do
  for _ in $(seq 1 20); do
    curl -fs "http://localhost:${port}/health" >/dev/null && break
    sleep 0.5
  done
done

hit() { curl -s -o /dev/null -w "%{http_code} $1\n" "$1"; }

echo "--> normal traffic"
for _ in $(seq 1 10); do
  hit "http://localhost:${ORDERS_PORT}/orders"
  hit "http://localhost:${PAYMENTS_PORT}/orders"
done

echo "--> errors"
hit "http://localhost:${ORDERS_PORT}/simulate-error?type=db&count=25"
hit "http://localhost:${ORDERS_PORT}/simulate-error?type=null&count=4"
hit "http://localhost:${PAYMENTS_PORT}/simulate-error?type=timeout&count=12"
hit "http://localhost:${PAYMENTS_PORT}/simulate-error?type=db&count=3"

echo
echo "Done. Fluentd flushes every ~10s; wait ~30s, then run: make run-now"
