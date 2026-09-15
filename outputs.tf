output "api_endpoints" {
  description = "Default *.execute-api invoke URL of each service."
  value       = { for k, a in aws_apigatewayv2_api.service : k => a.api_endpoint }
}

output "service_urls" {
  description = "Public base URL of each service — the custom domain where one exists, the raw invoke URL otherwise."
  value = {
    for k, a in aws_apigatewayv2_api.service :
    k => contains(keys(local.domain_services), k) ? "https://${local.domain_services[k].domain_name}" : a.api_endpoint
  }
}

output "graphql_url" {
  description = "GraphQL endpoint the Flutter app should call."
  value       = "${contains(keys(local.domain_services), "bff") ? "https://${local.domain_services["bff"].domain_name}" : aws_apigatewayv2_api.service["bff"].api_endpoint}/graphql"
}

output "custom_domain_targets" {
  description = "API Gateway regional target each Cloudflare CNAME points at."
  value       = { for k, d in aws_apigatewayv2_domain_name.service : k => d.domain_name_configuration[0].target_domain_name }
}

output "lambda_function_names" {
  description = "Name of each service's Lambda function."
  value       = { for k, f in aws_lambda_function.service : k => f.function_name }
}

output "dnssec_ds_record" {
  description = "DS record to publish at the registrar. DNSSEC is not enforced until it is."
  value       = one(cloudflare_zone_dnssec.this[*].ds)
}

output "aurora_cluster_arn" {
  description = "Aurora Serverless v2 cluster ARN (Data API resourceArn)."
  value       = aws_rds_cluster.aurora.arn
}

output "aurora_secret_arn" {
  description = "Secrets Manager ARN of the RDS-managed master credentials."
  value       = aws_rds_cluster.aurora.master_user_secret[0].secret_arn
}

output "aurora_database_name" {
  description = "Database the BFF runs its statements against."
  value       = aws_rds_cluster.aurora.database_name
}

output "aurora_cluster_endpoint" {
  description = "Writer endpoint (only reachable from inside the cluster VPC)."
  value       = aws_rds_cluster.aurora.endpoint
}