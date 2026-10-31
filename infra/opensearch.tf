# Single-node, single-AZ OpenSearch domain inside the VPC.
#
# Authentication: IAM only. There is no master user and no fine-grained access
# control; instead the domain's resource-based access policy below names the two
# IRSA roles and restricts each one to specific HTTP methods and paths:
#
#   fluentd    -> POST/PUT  on /_bulk and /app-logs-*   (write only)
#   log-doctor -> GET/POST  on /app-logs-*/_search      (read only)
#
# Every request must be SigV4-signed by one of those roles, and the domain is
# only reachable from inside the VPC on 443 from the EKS nodes.

locals {
  opensearch_domain_name = var.project_name
  opensearch_domain_arn  = "arn:${data.aws_partition.current.partition}:es:${var.region}:${data.aws_caller_identity.current.account_id}:domain/${local.opensearch_domain_name}"
  log_index_prefix       = "app-logs"
}

resource "aws_iam_service_linked_role" "opensearch" {
  count            = var.create_opensearch_service_linked_role ? 1 : 0
  aws_service_name = "opensearchservice.amazonaws.com"
}

resource "aws_security_group" "opensearch" {
  name        = "${var.project_name}-opensearch"
  description = "HTTPS from EKS worker nodes to OpenSearch"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "opensearch_from_nodes" {
  security_group_id            = aws_security_group.opensearch.id
  description                  = "HTTPS from EKS nodes"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = module.eks.node_security_group_id
}

data "aws_iam_policy_document" "opensearch_access" {
  statement {
    sid     = "FluentdWriteLogs"
    effect  = "Allow"
    actions = ["es:ESHttpPost", "es:ESHttpPut"]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.fluentd.arn]
    }
    resources = [
      "${local.opensearch_domain_arn}/_bulk",
      "${local.opensearch_domain_arn}/${local.log_index_prefix}-*",
    ]
  }

  statement {
    sid     = "LogDoctorReadOnlySearch"
    effect  = "Allow"
    actions = ["es:ESHttpGet", "es:ESHttpPost"]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.log_doctor.arn]
    }
    resources = [
      "${local.opensearch_domain_arn}/${local.log_index_prefix}-*/_search",
    ]
  }
}

resource "aws_opensearch_domain" "logs" {
  domain_name    = local.opensearch_domain_name
  engine_version = var.opensearch_engine_version

  cluster_config {
    instance_type          = var.opensearch_instance_type
    instance_count         = 1
    zone_awareness_enabled = false
  }

  ebs_options {
    ebs_enabled = true
    volume_type = "gp3"
    volume_size = var.opensearch_volume_size_gb
  }

  vpc_options {
    subnet_ids         = [module.vpc.private_subnets[0]]
    security_group_ids = [aws_security_group.opensearch.id]
  }

  encrypt_at_rest {
    enabled = true
  }

  node_to_node_encryption {
    enabled = true
  }

  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = "Policy-Min-TLS-1-2-2019-07"
  }

  # Note: Fluentd writes through /_bulk with the index named in the request
  # body, so its role can technically write to any index. It still cannot read,
  # search or delete anything. Use fine-grained access control if you need
  # index-level write restrictions.
  access_policies = data.aws_iam_policy_document.opensearch_access.json

  depends_on = [aws_iam_service_linked_role.opensearch]
}
