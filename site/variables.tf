variable "project_name" {
  description = "Name prefix for the stack's IAM resources and the Project tag."
  type        = string
  default     = "finances-site"
}

variable "aws_region" {
  description = "AWS region for the bucket and IAM resources."
  type        = string
  default     = "us-east-1"
}

variable "domain_name" {
  description = "Apex domain the site is served at. Also the S3 bucket name: Cloudflare forwards the original Host header and the S3 website endpoint routes by hostname."
  type        = string
  default     = "finances.app.br"
}

variable "www_redirect" {
  description = "Create www.<domain_name> and a 301 redirect from it to the apex."
  type        = bool
  default     = true
}

variable "github_repository" {
  description = "GitHub repository (owner/repo) whose Actions workflow deploys the site. The deploy role trusts only this repository."
  type        = string
  default     = "finances-app-br/site"
}

variable "github_deploy_branch" {
  description = "Branch of github_repository allowed to deploy. The deploy role trusts only this branch."
  type        = string
  default     = "main"
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub Actions OIDC provider. An AWS account holds only one; leave false when it already exists and the stack looks it up instead."
  type        = bool
  default     = false
}

variable "cloudflare_api_token" {
  description = "Escape hatch for the Cloudflare token. Leave empty and export CLOUDFLARE_API_TOKEN instead."
  type        = string
  default     = ""
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone that owns domain_name — the same zone the platform stack in ../ uses."
  type        = string

  validation {
    condition     = var.cloudflare_zone_id != ""
    error_message = "cloudflare_zone_id is required: the site is only reachable through Cloudflare."
  }
}

variable "tags" {
  description = "Extra tags merged into every taggable AWS resource."
  type        = map(string)
  default     = {}
}
