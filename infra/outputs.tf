# These outputs are read by scripts/render.sh and the Makefile.

output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "opensearch_endpoint" {
  description = "VPC endpoint hostname of the OpenSearch domain (no scheme)."
  value       = aws_opensearch_domain.logs.endpoint
}

output "fluentd_role_arn" {
  value = aws_iam_role.fluentd.arn
}

output "log_doctor_role_arn" {
  value = aws_iam_role.log_doctor.arn
}

output "bedrock_model_id" {
  value = var.bedrock_model_id
}

output "ecr_registry" {
  value = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

output "ecr_sample_app_url" {
  value = aws_ecr_repository.this["sample-app"].repository_url
}

output "ecr_log_doctor_url" {
  value = aws_ecr_repository.this["log-doctor"].repository_url
}
