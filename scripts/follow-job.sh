#!/usr/bin/env bash
# Wait for a Log Doctor Job's pod to start, then stream its logs until it exits.
#   scripts/follow-job.sh <job-name>
set -euo pipefail

NS=log-doctor
JOB="${1:?usage: follow-job.sh <job-name>}"
JOB="${JOB#job.batch/}"

echo "Waiting for job/${JOB} to start..."
for _ in $(seq 1 60); do
  if kubectl -n "${NS}" logs "job/${JOB}" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

kubectl -n "${NS}" logs -f "job/${JOB}"

if kubectl -n "${NS}" wait --for=condition=complete --timeout=30s "job/${JOB}" >/dev/null 2>&1; then
  echo "job/${JOB} succeeded"
else
  echo "job/${JOB} did not succeed - check: kubectl -n ${NS} describe job ${JOB}" >&2
  exit 1
fi
