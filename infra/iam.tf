# IAM roles for service accounts (IRSA).
#
# Each role trusts the cluster's OIDC provider, and only for one exact
# Kubernetes ServiceAccount (namespace + name). The EKS pod identity webhook
# injects AWS_ROLE_ARN / AWS_WEB_IDENTITY_TOKEN_FILE into pods using that SA,
# and the AWS SDKs (Ruby in Fluentd, boto3 in Log Doctor) pick them up.

data "aws_iam_policy_document" "irsa_trust" {
  for_each = {
    fluentd    = "system:serviceaccount:${var.fluentd_namespace}:${var.fluentd_service_account}"
    log_doctor = "system:serviceaccount:${var.log_doctor_namespace}:${var.log_doctor_service_account}"
  }

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = [each.value]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# ---------------------------------------------------------------------------
# Fluentd: write logs to OpenSearch
# ---------------------------------------------------------------------------
resource "aws_iam_role" "fluentd" {
  name               = "${var.project_name}-fluentd"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust["fluentd"].json
}

data "aws_iam_policy_document" "fluentd" {
  statement {
    sid     = "WriteLogs"
    actions = ["es:ESHttpPost", "es:ESHttpPut"]
    resources = [
      "${local.opensearch_domain_arn}/_bulk",
      "${local.opensearch_domain_arn}/${local.log_index_prefix}-*",
    ]
  }
}

resource "aws_iam_role_policy" "fluentd" {
  name   = "opensearch-write"
  role   = aws_iam_role.fluentd.id
  policy = data.aws_iam_policy_document.fluentd.json
}

# ---------------------------------------------------------------------------
# Log Doctor: read-only search + invoke one Bedrock model
# ---------------------------------------------------------------------------
locals {
  # Cross-region inference profiles are prefixed with a geography, e.g.
  # "apac.anthropic.<model>", "in.anthropic.<model>" or "global.anthropic.<model>".
  # Any "<geo>." in front of "anthropic." is treated as a profile prefix.
  bedrock_profile_prefix_regex = "^[a-z-]+\\.(anthropic\\.)"
  bedrock_is_profile           = can(regex(local.bedrock_profile_prefix_regex, var.bedrock_model_id))
  bedrock_foundation_model_id  = local.bedrock_is_profile ? replace(var.bedrock_model_id, "/${local.bedrock_profile_prefix_regex}/", "$1") : var.bedrock_model_id

  bedrock_profile_arn = "arn:${data.aws_partition.current.partition}:bedrock:${var.region}:${data.aws_caller_identity.current.account_id}:inference-profile/${var.bedrock_model_id}"
}

resource "aws_iam_role" "log_doctor" {
  name               = "${var.project_name}-log-doctor"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust["log_doctor"].json
}

data "aws_iam_policy_document" "log_doctor" {
  statement {
    sid       = "SearchLogsReadOnly"
    actions   = ["es:ESHttpGet", "es:ESHttpPost"]
    resources = ["${local.opensearch_domain_arn}/${local.log_index_prefix}-*/_search"]
  }

  # Direct foundation-model invocation (only when a plain model ID is used).
  dynamic "statement" {
    for_each = local.bedrock_is_profile ? [] : [1]
    content {
      sid       = "InvokeFoundationModel"
      actions   = ["bedrock:InvokeModel"]
      resources = ["arn:${data.aws_partition.current.partition}:bedrock:${var.region}::foundation-model/${var.bedrock_model_id}"]
    }
  }

  # Cross-region inference profile: allow the profile itself...
  dynamic "statement" {
    for_each = local.bedrock_is_profile ? [1] : []
    content {
      sid       = "InvokeInferenceProfile"
      actions   = ["bedrock:InvokeModel"]
      resources = [local.bedrock_profile_arn]
    }
  }

  # ...and the underlying model in whichever region the profile routes to,
  # but ONLY when the call arrives through that exact profile.
  dynamic "statement" {
    for_each = local.bedrock_is_profile ? [1] : []
    content {
      sid       = "InvokeModelViaProfileOnly"
      actions   = ["bedrock:InvokeModel"]
      resources = ["arn:${data.aws_partition.current.partition}:bedrock:*::foundation-model/${local.bedrock_foundation_model_id}"]
      condition {
        test     = "StringEquals"
        variable = "bedrock:InferenceProfileArn"
        values   = [local.bedrock_profile_arn]
      }
    }
  }
}

resource "aws_iam_role_policy" "log_doctor" {
  name   = "search-and-bedrock"
  role   = aws_iam_role.log_doctor.id
  policy = data.aws_iam_policy_document.log_doctor.json
}
