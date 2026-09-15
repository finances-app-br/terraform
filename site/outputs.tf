output "site_url" {
  description = "Public URL of the static site."
  value       = "https://${var.domain_name}"
}

output "bucket_name" {
  description = "S3 bucket the site workflow syncs into."
  value       = aws_s3_bucket.site.id
}

output "website_endpoint" {
  description = "S3 website endpoint Cloudflare proxies the site to."
  value       = aws_s3_bucket_website_configuration.site.website_endpoint
}

output "deploy_role_arn" {
  description = "Role the site's GitHub Actions workflow assumes. Store it as the AWS_DEPLOY_ROLE_ARN secret of github_repository."
  value       = aws_iam_role.deploy.arn
}
