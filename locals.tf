locals {
  tags = merge(
    {
      Project   = var.project_name
      ManagedBy = "terraform"
    },
    var.tags,
  )

  bff_path = "${path.module}/${var.bff_source_dir}"

  # Every public surface of the product, one entry per subdomain. Each entry
  # gets its own API Gateway, Lambda, IAM role and log group, so a bug on the
  # apex site can never reach the finance data behind the BFF: only the entry
  # with aurora_access = true is granted the Data API and the master secret.
  #
  # `web` and `api` have no application yet and run a placeholder handler —
  # swap their archive in lambda.tf for a real build when the portal lands.
  services = {
    web = {
      description   = "Placeholder for the apex web surface."
      domain_name   = var.web_domain_name
      cors_origins  = var.web_cors_allow_origins
      route_key     = "$default"
      aurora_access = false
      jwt_protected = false
    }
    api = {
      description   = "Placeholder for the public finances API."
      domain_name   = var.api_domain_name
      cors_origins  = var.api_cors_allow_origins
      route_key     = "$default"
      aurora_access = false
      jwt_protected = false
    }
    bff = {
      description   = "GraphQL sync BFF for the finance_app Flutter application."
      domain_name   = var.bff_domain_name
      cors_origins  = var.bff_cors_allow_origins
      route_key     = "POST /graphql"
      aurora_access = true
      jwt_protected = true
    }
  }

  # Services still running the generated stub rather than a real bundle.
  placeholder_services = { for k, s in local.services : k => s if !s.aurora_access }

  # A service only gets ACM + a custom domain when domains are enabled globally
  # and it actually has a hostname assigned.
  domain_services = {
    for k, s in local.services : k => s
    if var.enable_custom_domain && s.domain_name != ""
  }

  jwt_enabled = var.jwt_authorizer == null ? 0 : 1

  # The zip each function is deployed from: a real esbuild bundle for the BFF,
  # the generated stub for everything else.
  lambda_package = merge(
    {
      bff = {
        path = data.archive_file.bff.output_path
        hash = data.archive_file.bff.output_base64sha256
      }
    },
    {
      for k, a in data.archive_file.placeholder : k => {
        path = a.output_path
        hash = a.output_base64sha256
      }
    },
  )
}
