SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

IMAGE_TAG ?= 0.1.0
TF        := terraform -chdir=infra
NS        := log-doctor

# Terraform outputs, evaluated lazily (only when a target needs them).
tf_out          = $(shell $(TF) output -raw $(1))
REGION          = $(call tf_out,region)
CLUSTER         = $(call tf_out,cluster_name)
ECR_REGISTRY    = $(call tf_out,ecr_registry)
ECR_SAMPLE_APP  = $(call tf_out,ecr_sample_app_url)
ECR_LOG_DOCTOR  = $(call tf_out,ecr_log_doctor_url)

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------------------
# Infrastructure
# ---------------------------------------------------------------------------
.PHONY: infra-up
infra-up: ## Create VPC, EKS, OpenSearch, ECR and IAM (costs money!)
	@test -f infra/terraform.tfvars || { echo "Create infra/terraform.tfvars first (see terraform.tfvars.example)"; exit 1; }
	$(TF) init -input=false
	$(TF) apply
	$(MAKE) kubeconfig

.PHONY: kubeconfig
kubeconfig: ## Point kubectl at the demo cluster
	aws eks update-kubeconfig --region $(REGION) --name $(CLUSTER) --alias $(CLUSTER)

# ---------------------------------------------------------------------------
# Images
# ---------------------------------------------------------------------------
.PHONY: build-push
build-push: ## Build linux/amd64 images and push them to ECR
	aws ecr get-login-password --region $(REGION) | docker login --username AWS --password-stdin $(ECR_REGISTRY)
	docker build --platform linux/amd64 -t $(ECR_SAMPLE_APP):$(IMAGE_TAG) sample-app
	docker push $(ECR_SAMPLE_APP):$(IMAGE_TAG)
	docker build --platform linux/amd64 -t $(ECR_LOG_DOCTOR):$(IMAGE_TAG) log-doctor
	docker push $(ECR_LOG_DOCTOR):$(IMAGE_TAG)

# ---------------------------------------------------------------------------
# Kubernetes
# ---------------------------------------------------------------------------
.PHONY: render
render: ## Render manifests with Terraform outputs into build/
	IMAGE_TAG=$(IMAGE_TAG) scripts/render.sh

.PHONY: slack-secret
slack-secret: ## Create/update the Slack webhook Secret from env SLACK_WEBHOOK_URL
	@test -n "$${SLACK_WEBHOOK_URL:-}" || { echo "export SLACK_WEBHOOK_URL=https://hooks.slack.com/services/... first"; exit 1; }
	@kubectl apply -f build/k8s/namespaces.yaml >/dev/null 2>&1 || kubectl apply -f k8s/namespaces.yaml >/dev/null
	@kubectl -n $(NS) create secret generic slack-webhook \
	  --from-literal=webhook-url="$${SLACK_WEBHOOK_URL}" \
	  --dry-run=client -o yaml | kubectl apply -f -

.PHONY: deploy
deploy: render ## Deploy namespaces, service accounts, Fluentd, sample app and the CronJob
	kubectl apply -f build/k8s/namespaces.yaml
	kubectl apply -f build/k8s/serviceaccounts.yaml
	kubectl apply -f build/fluentd/
	kubectl apply -f build/sample-app/k8s/
	kubectl apply -f build/log-doctor/k8s/cronjob.yaml
	@kubectl -n $(NS) get secret slack-webhook >/dev/null 2>&1 || \
	  echo "WARNING: Secret $(NS)/slack-webhook not found - run 'make slack-secret' before the CronJob fires."
	kubectl -n logging rollout status ds/fluentd --timeout=180s
	kubectl -n apps rollout status deploy/orders-api --timeout=180s
	kubectl -n apps rollout status deploy/payments-api --timeout=180s

.PHONY: simulate-errors
simulate-errors: ## Send normal traffic + a burst of realistic errors to the sample apps
	scripts/simulate-errors.sh

.PHONY: run-now
run-now: ## Trigger the CronJob immediately as a one-off Job and follow its logs
	@job="log-doctor-manual-$$(date +%s)"; \
	kubectl -n $(NS) create job --from=cronjob/log-doctor "$$job"; \
	scripts/follow-job.sh "$$job"

.PHONY: dry-run
dry-run: render ## In-cluster run that prints instead of posting (SKIP_LLM=1 to skip Bedrock too)
	@args='"--dry-run"'; [[ -n "$${SKIP_LLM:-}" ]] && args='"--dry-run", "--skip-llm"'; \
	LOG_DOCTOR_ARGS="$$args" IMAGE_TAG=$(IMAGE_TAG) scripts/render.sh >/dev/null; \
	job="$$(kubectl create -f build/log-doctor/k8s/job-adhoc.yaml -o name)"; \
	scripts/follow-job.sh "$$job"

.PHONY: logs
logs: ## Logs of the most recent Log Doctor run
	@pod="$$(kubectl -n $(NS) get pods -l app.kubernetes.io/name=log-doctor --sort-by=.metadata.creationTimestamp -o name | tail -n1)"; \
	test -n "$$pod" || { echo "No Log Doctor pods yet - try 'make run-now'"; exit 1; }; \
	kubectl -n $(NS) logs "$$pod"

.PHONY: logs-fluentd
logs-fluentd: ## Tail Fluentd logs
	kubectl -n logging logs -l app.kubernetes.io/name=fluentd --tail=100 -f

.PHONY: logs-app
logs-app: ## Tail sample app logs
	kubectl -n apps logs -l app.kubernetes.io/part-of=log-doctor-demo --tail=50 -f --prefix

.PHONY: status
status: ## Show the demo's workloads
	kubectl -n logging get pods
	kubectl -n apps get pods
	kubectl -n $(NS) get cronjobs,jobs,pods

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------
.PHONY: undeploy
undeploy: ## Remove all Kubernetes resources created by this demo
	-kubectl delete -f build/log-doctor/k8s/cronjob.yaml --ignore-not-found
	-kubectl delete -f build/sample-app/k8s/ --ignore-not-found
	-kubectl delete -f build/fluentd/ --ignore-not-found
	-kubectl delete -f k8s/namespaces.yaml --ignore-not-found --wait=true

.PHONY: infra-down
infra-down: ## Delete Kubernetes resources, then destroy ALL AWS infrastructure
	-$(MAKE) undeploy
	$(TF) destroy
	rm -rf build

.PHONY: clean
clean: ## Remove rendered manifests
	rm -rf build
