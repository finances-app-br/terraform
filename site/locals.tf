locals {
  tags = merge(
    {
      Project   = var.project_name
      ManagedBy = "terraform"
    },
    var.tags,
  )

  www_hosts = var.www_redirect ? ["www.${var.domain_name}"] : []
  hosts     = concat([var.domain_name], local.www_hosts)

  # Every Cloudflare rule is scoped to these expressions, so the API Gateway
  # services the platform stack runs in the same zone never pick up the site's
  # cache, SSL or header rules.
  hosts_expression = "(http.host in {${join(" ", [for host in local.hosts : "\"${host}\""])}})"
  apex_expression  = "(http.host eq \"${var.domain_name}\")"
}
