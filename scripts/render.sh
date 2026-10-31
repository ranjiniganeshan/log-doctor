#!/usr/bin/env bash
# Render Kubernetes manifests: substitute Terraform outputs + image tags into
# every *.yaml under k8s/, fluentd/, sample-app/k8s/ and log-doctor/k8s/,
# writing the results to build/. Only the variables listed below are
# substituted, so other "$" characters in the manifests are left alone.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/build"
IMAGE_TAG="${IMAGE_TAG:?IMAGE_TAG must be set}"

command -v envsubst >/dev/null || { echo "envsubst not found (macOS: brew install gettext)" >&2; exit 1; }

tf_out() { terraform -chdir="${ROOT}/infra" output -raw "$1"; }

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -c1-16; }

export AWS_REGION="$(tf_out region)"
export OPENSEARCH_HOST="$(tf_out opensearch_endpoint)"
export FLUENTD_ROLE_ARN="$(tf_out fluentd_role_arn)"
export LOG_DOCTOR_ROLE_ARN="$(tf_out log_doctor_role_arn)"
export MODEL_ID="$(tf_out bedrock_model_id)"
export SAMPLE_APP_IMAGE="$(tf_out ecr_sample_app_url):${IMAGE_TAG}"
export LOG_DOCTOR_IMAGE="$(tf_out ecr_log_doctor_url):${IMAGE_TAG}"
export FLUENTD_CONFIG_SHA="$(sha256 "${ROOT}/fluentd/configmap.yaml")"
export LOG_DOCTOR_ARGS="${LOG_DOCTOR_ARGS:-\"--dry-run\"}"

VARS='${AWS_REGION} ${OPENSEARCH_HOST} ${FLUENTD_ROLE_ARN} ${LOG_DOCTOR_ROLE_ARN} ${MODEL_ID} ${SAMPLE_APP_IMAGE} ${LOG_DOCTOR_IMAGE} ${FLUENTD_CONFIG_SHA} ${LOG_DOCTOR_ARGS}'

rm -rf "${OUT}"
cd "${ROOT}"
for src in k8s/*.yaml fluentd/*.yaml sample-app/k8s/*.yaml log-doctor/k8s/*.yaml log-doctor/k8s/*.tpl; do
  dest="${OUT}/${src%.tpl}"
  mkdir -p "$(dirname "${dest}")"
  envsubst "${VARS}" < "${src}" > "${dest}"
done

echo "Rendered manifests into ${OUT#"${ROOT}/"}/ (image tag ${IMAGE_TAG}, region ${AWS_REGION})"
