variable "project_name" {
  description = "Name prefix applied to all resources."
  type        = string
  default     = "finance-app-bff"
}

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

# ----------------------------------------------- Aurora Serverless v2 (PG) ---

variable "aurora_engine_version" {
  description = "Aurora PostgreSQL engine version. Scale-to-zero needs 16.3+/15.7+/14.12+."
  type        = string
  default     = "16.6"
}

variable "aurora_database_name" {
  description = "Database created inside the cluster and used by the BFF."
  type        = string
  default     = "finance"
}

variable "aurora_master_username" {
  description = "Master user. Its password is generated and rotated by RDS in Secrets Manager."
  type        = string
  default     = "bff_admin"
}

variable "aurora_min_capacity" {
  description = "Minimum Aurora Capacity Units. 0 lets the cluster pause when idle."
  type        = number
  default     = 0
}

variable "aurora_max_capacity" {
  description = "Maximum Aurora Capacity Units the cluster may scale up to."
  type        = number
  default     = 2
}

variable "aurora_seconds_until_auto_pause" {
  description = "Idle seconds before scaling to zero (only when aurora_min_capacity = 0)."
  type        = number
  default     = 300
}

variable "aurora_backup_retention_days" {
  description = "Automated backup retention, in days."
  type        = number
  default     = 7
}

variable "aurora_deletion_protection" {
  description = "Block `terraform destroy` from deleting the cluster."
  type        = bool
  default     = false
}

variable "aurora_skip_final_snapshot" {
  description = "Skip the final snapshot when the cluster is destroyed."
  type        = bool
  default     = false
}

variable "aurora_vpc_cidr" {
  description = "CIDR of the private VPC that hosts the cluster."
  type        = string
  default     = "10.42.0.0/16"
}

variable "aurora_subnet_count" {
  description = "Number of AZs/subnets in the DB subnet group (Aurora requires at least 2)."
  type        = number
  default     = 2

  validation {
    condition     = var.aurora_subnet_count >= 2
    error_message = "Aurora needs a subnet group spanning at least two availability zones."
  }
}

# ----------------------------------------------------------------- Lambda ---

variable "lambda_runtime" {
  description = "Lambda Node.js runtime. Bump to nodejs24.x once available in your region."
  type        = string
  default     = "nodejs22.x"
}

variable "lambda_memory_size" {
  description = "Lambda memory (MB). CPU scales with memory."
  type        = number
  default     = 256
}

variable "lambda_timeout" {
  description = "Lambda timeout (seconds)."
  type        = number
  default     = 15
}

variable "log_retention_days" {
  description = "CloudWatch log retention for the Lambda log group."
  type        = number
  default     = 14
}

# ------------------------------------------------------------- API Gateway ---

variable "cors_allow_origins" {
  description = "Allowed CORS origins for the HTTP API. Restrict in production."
  type        = list(string)
  default     = ["*"]
}

variable "jwt_authorizer" {
  description = <<-EOT
    Optional API Gateway JWT authorizer (Cognito, Auth0, ...). When set, the
    /graphql route requires a valid bearer token and the BFF reads the user id
    from the `sub` claim. Leave null for local/dev (identity via x-user-id).
  EOT
  type = object({
    issuer    = string       # e.g. https://cognito-idp.us-east-1.amazonaws.com/<pool-id>
    audiences = list(string) # e.g. ["<app-client-id>"]
  })
  default = null
}

# ------------------------------------------------- Cloudflare custom domain ---

variable "enable_custom_domain" {
  description = "Create the API Gateway custom domain + ACM cert + Cloudflare DNS."
  type        = bool
  default     = true
}

variable "domain_name" {
  description = "FQDN served by Cloudflare, e.g. api.finance.example.com."
  type        = string
  default     = ""
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token with DNS edit rights on the zone."
  type        = string
  default     = ""
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone id that owns domain_name."
  type        = string
  default     = ""
}

variable "cloudflare_proxied" {
  description = "Route app traffic through Cloudflare's proxy (orange cloud)."
  type        = bool
  default     = true
}

# --------------------------------------------------------------------- tags ---

variable "tags" {
  description = "Extra tags merged into every taggable resource."
  type        = map(string)
  default     = {}
}
