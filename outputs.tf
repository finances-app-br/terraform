output "api_endpoint" {
  description = "Default API Gateway invoke URL."
  value       = aws_apigatewayv2_api.this.api_endpoint
}

output "graphql_url" {
  description = "GraphQL endpoint the Flutter app should call."
  value       = local.custom_domain_enabled == 1 ? "https://${var.domain_name}/graphql" : "${aws_apigatewayv2_api.this.api_endpoint}/graphql"
}

output "custom_domain_target" {
  description = "API Gateway regional target the Cloudflare CNAME points at."
  value       = one(aws_apigatewayv2_domain_name.this[*].domain_name_configuration[0].target_domain_name)
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

output "lambda_function_name" {
  description = "Name of the BFF Lambda function."
  value       = aws_lambda_function.bff.function_name
}
