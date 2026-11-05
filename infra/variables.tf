variable "region" {
  description = "AWS region for every resource in this demo."
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Name prefix used for the cluster, domain, ECR repos and IAM roles."
  type        = string
  default     = "log-doctor"
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------
variable "vpc_cidr" {
  description = "CIDR block for the demo VPC."
  type        = string
  default     = "10.40.0.0/16"
}

# ---------------------------------------------------------------------------
# EKS
# ---------------------------------------------------------------------------
variable "kubernetes_version" {
  description = "EKS Kubernetes version. Pick one in *standard* support; extended support costs 6x more."
  type        = string
  default     = "1.36"
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint. Set this to your own IP (x.x.x.x/32)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "node_instance_type" {
  description = "Instance type for the managed node group."
  type        = string
  default     = "t3.medium"
}

variable "node_desired_size" {
  description = "Desired node count. One t3.medium fits the whole demo."
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum node count."
  type        = number
  default     = 2
}

# ---------------------------------------------------------------------------
# OpenSearch
# ---------------------------------------------------------------------------
variable "opensearch_engine_version" {
  description = "OpenSearch engine version."
  type        = string
  default     = "OpenSearch_2.19"
}

variable "opensearch_instance_type" {
  description = "OpenSearch data node instance type (smallest supported)."
  type        = string
  default     = "t3.small.search"
}

variable "opensearch_volume_size_gb" {
  description = "EBS volume size per OpenSearch node, in GiB."
  type        = number
  default     = 10
}

variable "create_opensearch_service_linked_role" {
  description = "Create the AWSServiceRoleForAmazonOpenSearchService role. Set false if your account already has it."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Bedrock
# ---------------------------------------------------------------------------
variable "bedrock_model_id" {
  description = <<-EOT
    Bedrock model Log Doctor will call through the Converse API. Either a
    model ID that supports on-demand use in your region (e.g.
    "openai.gpt-oss-20b-1:0") or a cross-region inference profile ID (e.g.
    "global.amazon.nova-2-lite-v1:0").
    List what's available with:
      aws bedrock list-inference-profiles --region ap-south-1
      aws bedrock list-foundation-models --region ap-south-1 --by-inference-type ON_DEMAND
  EOT
  type        = string

  validation {
    condition     = can(regex("^([a-z-]+\\.)?[a-z0-9-]+\\.[A-Za-z0-9.:_-]+$", var.bedrock_model_id))
    error_message = "bedrock_model_id must look like <provider>.<model> or <geo>.<provider>.<model>."
  }
}

# ---------------------------------------------------------------------------
# Kubernetes identities that receive IAM roles (must match k8s/serviceaccounts.yaml)
# ---------------------------------------------------------------------------
variable "fluentd_namespace" {
  type    = string
  default = "logging"
}

variable "fluentd_service_account" {
  type    = string
  default = "fluentd"
}

variable "log_doctor_namespace" {
  type    = string
  default = "log-doctor"
}

variable "log_doctor_service_account" {
  type    = string
  default = "log-doctor"
}
