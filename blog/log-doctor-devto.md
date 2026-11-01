---
title: "Log Doctor: I let Claude read my Kubernetes error logs every 15 minutes"
published: false
description: "A hands-on build: EKS + Fluentd + OpenSearch + Claude on Amazon Bedrock + Slack. The script does the searching; the LLM just explains."
tags: aws, kubernetes, ai, devops
cover_image: https://raw.githubusercontent.com/ranjiniganeshan/log-doctor/main/docs/images/09-slack-message.png
---

<!--
  DRAFT - written alongside the hands-on run.
  TODO markers = things to fill in from the real run (times, numbers, your own words).
  Images: commit screenshots to docs/images/ and push; dev.to needs the raw GitHub URLs used below.
-->

Every on-call engineer knows this moment: an alert fires, you open the log search, and you're looking at hundreds of stack traces. Most of them say the same thing, and a few are the ones that actually matter.

I wanted to see whether an LLM could do that first pass for me. Not an agent that roams around my cluster, just something small and predictable: **every 15 minutes, collect the errors, group them, and have Claude explain in plain English what's going on, the likely cause, and what to check first.** Then post that to Slack. And if there are no errors, post nothing.

I called it **Log Doctor**. This post walks through the whole build, every command included, so you can run it yourself and tear it down the same day.

👉 Code: [github.com/ranjiniganeshan/log-doctor](https://github.com/ranjiniganeshan/log-doctor)

## What we're building

```
Sample microservice → Fluentd DaemonSet → OpenSearch → Log Doctor CronJob → Bedrock (Claude) → Slack
```

![Architecture](https://raw.githubusercontent.com/ranjiniganeshan/log-doctor/main/docs/images/00-architecture.png)
<!-- TODO: screenshot of the Mermaid diagram as rendered on the GitHub README -->

- **Two small FastAPI services** (`orders-api`, `payments-api`) write structured JSON logs to stdout. They have an endpoint that produces realistic failures on demand: database pool exhaustion, an upstream timeout, and the classic `NoneType` bug.
- **Fluentd** runs as a DaemonSet. It tails container logs, adds Kubernetes metadata, and ships everything to **Amazon OpenSearch** in daily indices (`app-logs-2026.11.01`).
- **Log Doctor** is a Kubernetes **CronJob** (`*/15 * * * *`). It runs a single aggregation query: errors from the last 15 minutes, grouped by service, with the top messages, their counts, and two sample lines each. It sends that compact summary to **Claude on Amazon Bedrock** and posts the reply to **Slack**.

One design decision shapes everything else: **Claude never touches OpenSearch.** My script does all the fetching and trimming, and the model only ever sees a few kilobytes of pre-aggregated text. That keeps it cheap, keeps it predictable, and makes it easy to explain to a security team.

## Before you start

You'll need an AWS account and these tools locally: AWS CLI v2, Terraform (≥ 1.6), kubectl, Docker and `envsubst`. I'm using **ap-south-1 (Mumbai)**.

One thing caught me right at the start. My AWS CLI was old enough that it didn't have `aws bedrock-runtime converse` at all, so upgrade first:

```bash
curl -o /tmp/AWSCLIV2.pkg https://awscli.amazonaws.com/AWSCLIV2.pkg
sudo installer -pkg /tmp/AWSCLIV2.pkg -target /
aws --version
```

Then grab the code:

```bash
git clone https://github.com/ranjiniganeshan/log-doctor.git
cd log-doctor
```

> 💸 This creates real, billable resources (an EKS cluster, an OpenSearch domain, a NAT gateway). Plan on roughly **US$6 a day**, and run the teardown at the end.

## Step 1: Turn on Claude in Bedrock

Bedrock now enables models automatically the first time you use them. You no longer flip a switch per model on a "Model access" page. Anthropic models still need two one-time things per account, though:

1. **The use-case form.** In the Bedrock console (Mumbai region), open **Model catalog**, pick a Claude model, and submit the short form Anthropic asks for.
2. **A first call from your own credentials.** That first invocation creates the AWS Marketplace subscription, which needs Marketplace permissions. Log Doctor's IAM role deliberately doesn't have those, so make the first call yourself.

In Mumbai, Claude is offered through **cross-region inference profiles**. These are IDs starting with `apac.`, which can route a request to another APAC region when there's capacity. List them:

```bash
aws bedrock list-inference-profiles --region ap-south-1 \
  --query "inferenceProfileSummaries[?contains(inferenceProfileId,'anthropic')].[inferenceProfileId,inferenceProfileName]" \
  --output table
```

Pick one (a Haiku- or Sonnet-class model is plenty for this) and say hello:

```bash
export MODEL_ID="apac.anthropic.<the-profile-you-picked>"

aws bedrock-runtime converse --region ap-south-1 --model-id "$MODEL_ID" \
  --messages '[{"role":"user","content":[{"text":"Reply with OK"}]}]' \
  --inference-config '{"maxTokens":50}'
```

![Bedrock inference profiles and the first converse call](https://raw.githubusercontent.com/ranjiniganeshan/log-doctor/main/docs/images/01-bedrock-profiles.png)

Seeing `"OK"` come back means the model side is ready.
<!-- TODO: which model you picked and why, one sentence -->

## Step 2: A Slack incoming webhook

The simplest way to post to Slack is an incoming webhook: no bot token and no OAuth dance.

1. Go to [api.slack.com/apps](https://api.slack.com/apps) → **Create New App** → **From scratch**, call it "Log Doctor", and pick your workspace.
2. Open **Incoming Webhooks**, switch it on, then **Add New Webhook to Workspace** and pick a channel.
3. Copy the URL. Treat it like a password, because anyone who has it can post to that channel.

![Slack incoming webhook](https://raw.githubusercontent.com/ranjiniganeshan/log-doctor/main/docs/images/02-slack-webhook.png)

I keep the URL in my shell only. It never goes into a file in the repo:

```bash
export SLACK_WEBHOOK_URL='https://hooks.slack.com/services/...'
```

## Step 3: Infrastructure with Terraform

The `infra/` folder creates everything:

| File | What it creates |
|---|---|
| `vpc.tf` | VPC across 2 AZs (EKS needs that) with **one** NAT gateway |
| `eks.tf` | EKS 1.36 with one `t3.medium` managed node, in one AZ |
| `opensearch.tf` | A single `t3.small.search` OpenSearch node in the VPC, 10 GB gp3, encrypted, HTTPS only |
| `ecr.tf` | Two ECR repos for our images |
| `iam.tf` | One IAM role for Fluentd and one for Log Doctor (IRSA) |

Everything that's billed per AZ (the node, OpenSearch, the NAT gateway) sits in a single AZ. That's fine for a demo and saves money and cross-AZ traffic.

### How the pods authenticate (no passwords anywhere)

This was the part I thought about most. Both Fluentd and Log Doctor have to talk to OpenSearch, and I didn't want a master username and password sitting in a Kubernetes Secret.

So the domain uses **IAM-only access**. Each workload gets its own IAM role through **IRSA** (IAM Roles for Service Accounts), and the OpenSearch access policy limits each role to specific HTTP methods *and paths*:

```hcl
statement {
  sid     = "FluentdWriteLogs"
  actions = ["es:ESHttpPost", "es:ESHttpPut"]
  principals { type = "AWS", identifiers = [aws_iam_role.fluentd.arn] }
  resources = [
    "${local.opensearch_domain_arn}/_bulk",
    "${local.opensearch_domain_arn}/app-logs-*",
  ]
}

statement {
  sid     = "LogDoctorReadOnlySearch"
  actions = ["es:ESHttpGet", "es:ESHttpPost"]
  principals { type = "AWS", identifiers = [aws_iam_role.log_doctor.arn] }
  resources = ["${local.opensearch_domain_arn}/app-logs-*/_search"]
}
```

Fluentd can write and nothing else. Log Doctor can run `_search` on `app-logs-*` and nothing else. It can't delete an index or even list them.

Each role's trust policy is pinned to one exact Kubernetes ServiceAccount, so another pod in the cluster can't borrow it:

```hcl
condition {
  test     = "StringEquals"
  variable = "${module.eks.oidc_provider}:sub"
  values   = ["system:serviceaccount:log-doctor:log-doctor"]
}
```

I went with IRSA rather than the newer EKS Pod Identity because Fluentd's OpenSearch plugin has built-in config for web-identity role assumption. Using the same mechanism for both pods meant one less thing to explain.

The honest trade-off: Fluentd writes through `/_bulk`, where the index name is in the request body, so its role could technically write to *any* index. It still can't read or delete anything. If that matters to you, OpenSearch fine-grained access control is the next step up.

### Bedrock permissions: just one model

Log Doctor's role can call exactly one model, and only through the inference profile you chose. Cross-region profiles need two grants: one on the profile itself, and one on the underlying model in whichever region the request lands in, with a condition so the model can't be called directly:

```hcl
statement {
  sid       = "InvokeModelViaProfileOnly"
  actions   = ["bedrock:InvokeModel"]
  resources = ["arn:aws:bedrock:*::foundation-model/${local.bedrock_foundation_model_id}"]
  condition {
    test     = "StringEquals"
    variable = "bedrock:InferenceProfileArn"
    values   = [local.bedrock_profile_arn]
  }
}
```

### Run it

Copy the example variables file and fill in three things:

```bash
cp infra/terraform.tfvars.example infra/terraform.tfvars

# your public IP, so only you can reach the EKS API
curl -s https://checkip.amazonaws.com

# does the OpenSearch service-linked role already exist in this account?
aws iam get-role --role-name AWSServiceRoleForAmazonOpenSearchService >/dev/null 2>&1 \
  && echo "exists -> set create_opensearch_service_linked_role = false" \
  || echo "missing -> keep it true"
```

```hcl
# infra/terraform.tfvars
region                                = "ap-south-1"
cluster_endpoint_public_access_cidrs  = ["<your-ip>/32"]
bedrock_model_id                      = "apac.anthropic.<the-profile-you-picked>"
create_opensearch_service_linked_role = true
```

Then:

```bash
make infra-up
```

That's `terraform init` + `terraform apply`, followed by `aws eks update-kubeconfig`. It took **TODO minutes** for me; OpenSearch and the EKS control plane take most of that time.
<!-- TODO: actual duration, and anything you noticed while waiting -->

![terraform apply complete](https://raw.githubusercontent.com/ranjiniganeshan/log-doctor/main/docs/images/03-terraform-apply.png)

```bash
kubectl get nodes
```

One `t3.medium`, `Ready`. That's the whole cluster.

## Step 4: Build and push the images

<!-- IN PROGRESS: fill in after running -->

```bash
make build-push
```

This logs in to ECR and builds both images for `linux/amd64`. That matters if you're on an Apple Silicon Mac, because the nodes are x86. Then it pushes them with tag `0.1.0`.

![Images in ECR](https://raw.githubusercontent.com/ranjiniganeshan/log-doctor/main/docs/images/04-ecr-images.png)

## Step 5: Deploy to the cluster

<!-- IN PROGRESS -->

```bash
make slack-secret   # creates the Secret straight from $SLACK_WEBHOOK_URL
make deploy
make status
```

![Everything running](https://raw.githubusercontent.com/ranjiniganeshan/log-doctor/main/docs/images/05-pods-running.png)

<!-- TODO: Fluentd config walkthrough (CRI parsing, exclude kube-system, JSON lift, daily index) -->

## Step 6: Break things on purpose

<!-- TODO -->

## Step 7: Let the doctor take a look

<!-- TODO: dry-run SKIP_LLM=1 (the prompt), dry-run (the summary), run-now (Slack) -->

## What it costs

<!-- TODO: real numbers from Cost Explorer, Project = log-doctor tag; token counts from the Slack footer -->

## Tearing it all down

<!-- TODO -->

## What I'd do next

<!-- TODO -->
