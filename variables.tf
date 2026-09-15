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

variable "bff_source_dir" {
  description = "Path to the BFF source checkout, relative to this module. Built and packaged into the Lambda bundle."
  type        = string
  default     = "../app-bff"
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
  description = "Lambda Node.js runtime, shared by every service."
  type        = string
  default     = "nodejs24.x"
}

variable "lambda_memory_size" {
  description = "Lambda memory (MB). CPU scales with memory."
  type        = number
  default     = 128
}

variable "lambda_timeout" {
  description = "Lambda timeout (seconds)."
  type        = number
  default     = 15
}

variable "lambda_reserved_concurrency" {
  description = <<-EOT
    Reserved concurrent executions per function. -1 leaves the function on the
    unreserved account pool; a positive value caps both cost and blast radius
    (and 0 disables the function entirely).
  EOT
  type        = number
  default     = -1

  validation {
    condition     = var.lambda_reserved_concurrency >= -1
    error_message = "lambda_reserved_concurrency must be -1 (unreserved) or a non-negative cap."
  }
}

variable "enable_xray_tracing" {
  description = "Turn on AWS X-Ray active tracing and grant the functions the matching IAM permissions."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "CloudWatch log retention for the Lambda log groups."
  type        = number
  default     = 14
}

# ------------------------------------------------------------- API Gateway ---

# One list per service. An empty list omits the CORS configuration entirely,
# which is the right answer for a surface no browser calls cross-origin.
# Never "*": these APIs accept credential-bearing headers.

variable "web_cors_allow_origins" {
  description = "Allowed CORS origins for the apex web API Gateway. Empty omits CORS."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.web_cors_allow_origins, "*")
    error_message = "Wildcard CORS is unsafe here — list the origins explicitly."
  }
}

variable "api_cors_allow_origins" {
  description = "Allowed CORS origins for the public API. Empty omits CORS."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.api_cors_allow_origins, "*")
    error_message = "Wildcard CORS is unsafe here — list the origins explicitly."
  }
}

variable "bff_cors_allow_origins" {
  description = "Allowed CORS origins for the GraphQL sync BFF. Empty omits CORS."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.bff_cors_allow_origins, "*")
    error_message = "Wildcard CORS is unsafe here — list the origins explicitly."
  }
}

variable "throttling_rate_limit" {
  description = "Steady-state requests per second allowed by each API Gateway stage."
  type        = number
  default     = 50

  validation {
    condition     = var.throttling_rate_limit > 0
    error_message = "throttling_rate_limit must be greater than zero."
  }
}

variable "throttling_burst_limit" {
  description = "Burst capacity (concurrent requests) allowed by each API Gateway stage."
  type        = number
  default     = 100

  validation {
    condition     = var.throttling_burst_limit >= var.throttling_rate_limit
    error_message = "throttling_burst_limit must be at least throttling_rate_limit."
  }
}

variable "jwt_authorizer" {
  description = <<-EOT
    Optional API Gateway JWT authorizer (Cognito, Auth0, ...) for the BFF. When
    set, the /graphql route requires a valid bearer token and the BFF reads the
    user id from the `sub` claim. Leave null for local/dev (identity via
    x-user-id).
  EOT
  type = object({
    issuer    = string       # e.g. https://cognito-idp.us-east-1.amazonaws.com/<pool-id>
    audiences = list(string) # e.g. ["<app-client-id>"]
  })
  default = null
}

# ------------------------------------------------- Cloudflare custom domain ---

variable "enable_custom_domain" {
  description = "Create the API Gateway custom domains + ACM certs + Cloudflare DNS. False falls back to the raw *.execute-api URLs."
  type        = bool
  default     = true
}

variable "web_domain_name" {
  description = "Domain for the web surface. Empty skips the web custom domain. Not the zone apex: that record belongs to the static site stack in site/."
  type        = string
  default     = ""
}

variable "api_domain_name" {
  description = "Domain for the public API, e.g. api.finances.app.br. Empty skips the api custom domain."
  type        = string
  default     = ""
}

variable "bff_domain_name" {
  description = "Domain for the GraphQL sync BFF, e.g. bff.finances.app.br. Empty skips the bff custom domain."
  type        = string
  default     = ""
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token with DNS edit (and Zone Settings edit, if managing zone security) rights on the zone."
  type        = string
  default     = ""
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone id that owns the domains above."
  type        = string
  default     = ""
}

variable "cloudflare_proxied" {
  description = "Route app traffic through Cloudflare's proxy (orange cloud)."
  type        = bool
  default     = true
}

# -------------------------------------------------------- domain hardening ---
#
# Everything below is ZONE-WIDE: it applies to every hostname in
# cloudflare_zone_id, not just the domains this stack creates. Leave
# manage_cloudflare_zone_security = false if the zone is shared with something
# Terraform does not own.

variable "manage_cloudflare_zone_security" {
  description = "Let Terraform own the zone's SSL mode, HTTPS redirect and HSTS header. Zone-wide."
  type        = bool
  default     = false
}

variable "cloudflare_ssl_mode" {
  description = <<-EOT
    Cloudflare edge-to-origin SSL mode. "strict" requires a valid, trusted
    certificate on the origin — which API Gateway custom domains have, so it is
    the right setting here. Anything below "full" lets the origin leg run in
    cleartext.
  EOT
  type        = string
  default     = "strict"

  validation {
    condition     = contains(["off", "flexible", "full", "strict"], var.cloudflare_ssl_mode)
    error_message = "cloudflare_ssl_mode must be one of: off, flexible, full, strict."
  }
}

variable "hsts_max_age" {
  description = "Strict-Transport-Security max-age in seconds (31536000 = 1 year). 0 disables the header."
  type        = number
  default     = 31536000

  validation {
    condition     = var.hsts_max_age >= 0
    error_message = "hsts_max_age cannot be negative."
  }
}

variable "hsts_preload" {
  description = <<-EOT
    Add the `preload` directive. Only enable once every subdomain is
    HTTPS-only — browsers honour a preloaded entry for months and removal is
    slow.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.hsts_preload || var.hsts_max_age >= 31536000
    error_message = "HSTS preload requires hsts_max_age of at least 31536000 (1 year)."
  }
}

variable "enable_dnssec" {
  description = <<-EOT
    Turn on DNSSEC signing for the zone. Cloudflare signs immediately, but the
    zone is only actually protected once you publish the DS record (see the
    `dnssec_ds_record` output) at your registrar.
  EOT
  type        = bool
  default     = false
}

variable "manage_caa_records" {
  description = "Publish CAA records restricting which CAs may issue certificates for the zone."
  type        = bool
  default     = false
}

variable "caa_issuers" {
  description = <<-EOT
    CAs allowed to issue for the zone. The default covers ACM (amazon.com) plus
    the authorities Cloudflare's Universal SSL rotates between — dropping one of
    those can silently break edge-certificate renewal.
  EOT
  type        = list(string)
  default = [
    "amazon.com",
    "letsencrypt.org",
    "pki.goog",
    "digicert.com",
    "sectigo.com",
    "comodoca.com",
    "ssl.com",
  ]

  validation {
    condition     = length(var.caa_issuers) > 0
    error_message = "caa_issuers cannot be empty — an empty issue set forbids all certificate issuance."
  }
}

variable "caa_report_email" {
  description = "Address CAs report CAA violations to (published as an `iodef` record). Empty publishes no iodef record."
  type        = string
  default     = ""
}

# --------------------------------------------------------------------- tags ---

variable "tags" {
  description = "Extra tags merged into every taggable resource."
  type        = map(string)
  default     = {}
}
