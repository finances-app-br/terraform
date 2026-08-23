locals {
  tags = merge(
    {
      Project   = var.project_name
      ManagedBy = "terraform"
    },
    var.tags,
  )

  custom_domain_enabled = var.enable_custom_domain ? 1 : 0
  jwt_enabled           = var.jwt_authorizer == null ? 0 : 1
}
