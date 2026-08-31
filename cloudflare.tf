# DNS records that prove domain ownership to ACM, one per certificate.
resource "cloudflare_dns_record" "cert_validation" {
  for_each = local.domain_services

  zone_id = var.cloudflare_zone_id
  name    = trimsuffix(tolist(aws_acm_certificate.service[each.key].domain_validation_options)[0].resource_record_name, ".")
  type    = tolist(aws_acm_certificate.service[each.key].domain_validation_options)[0].resource_record_type
  content = trimsuffix(tolist(aws_acm_certificate.service[each.key].domain_validation_options)[0].resource_record_value, ".")
  ttl     = 60
  proxied = false # validation records must resolve directly to AWS
}

# Public records clients hit. Proxied so Cloudflare fronts the API Gateway
# custom domains. The apex record relies on Cloudflare's CNAME flattening.
resource "cloudflare_dns_record" "service" {
  for_each = local.domain_services

  zone_id = var.cloudflare_zone_id
  name    = each.value.domain_name
  type    = "CNAME"
  content = aws_apigatewayv2_domain_name.service[each.key].domain_name_configuration[0].target_domain_name
  ttl     = 1 # must be 1 (automatic) when proxied
  proxied = var.cloudflare_proxied
}

# ------------------------------------------------------- zone hardening ---
#
# Everything below is zone-wide, not per-service: it applies to every hostname
# in cloudflare_zone_id. Gated on manage_cloudflare_zone_security so a shared
# zone can opt out.

# API Gateway custom domains present a valid, publicly trusted ACM certificate,
# so "strict" costs nothing and closes the cleartext origin leg that "flexible"
# would leave open.
resource "cloudflare_zone_setting" "ssl" {
  count = var.manage_cloudflare_zone_security ? 1 : 0

  zone_id    = var.cloudflare_zone_id
  setting_id = "ssl"
  value      = var.cloudflare_ssl_mode
}

# HSTS only means anything if the first, plaintext request is redirected too.
resource "cloudflare_zone_setting" "always_use_https" {
  count = var.manage_cloudflare_zone_security ? 1 : 0

  zone_id    = var.cloudflare_zone_id
  setting_id = "always_use_https"
  value      = "on"
}

# Cloudflare injects HSTS at the edge, so no application code has to.
# hsts_max_age = 0 turns the header off without removing this resource.
resource "cloudflare_zone_setting" "security_header" {
  count = var.manage_cloudflare_zone_security ? 1 : 0

  zone_id    = var.cloudflare_zone_id
  setting_id = "security_header"

  value = {
    strict_transport_security = {
      enabled            = var.hsts_max_age > 0
      max_age            = var.hsts_max_age
      include_subdomains = true
      preload            = var.hsts_preload
      nosniff            = true
    }
  }
}

# Cloudflare starts signing straight away, but resolvers only validate once the
# DS record from the `dnssec_ds_record` output is published at the registrar.
resource "cloudflare_zone_dnssec" "this" {
  count = var.enable_dnssec ? 1 : 0

  zone_id = var.cloudflare_zone_id
  status  = "active"
}

# CAA records are published at the zone apex, which is not necessarily one of
# the service domains — ask Cloudflare for the zone's own name.
data "cloudflare_zone" "this" {
  count = var.manage_caa_records ? 1 : 0

  zone_id = var.cloudflare_zone_id
}

# Restricts certificate issuance to the CAs actually in play: ACM for the
# origin certs, plus the authorities Cloudflare's Universal SSL rotates
# between. `issuewild` mirrors `issue` so a wildcard cannot be issued by a CA
# the exact-match rule forbids.
resource "cloudflare_dns_record" "caa_issue" {
  for_each = var.manage_caa_records ? toset(var.caa_issuers) : toset([])

  zone_id = var.cloudflare_zone_id
  name    = data.cloudflare_zone.this[0].name
  type    = "CAA"
  ttl     = 3600

  data = {
    flags = 0
    tag   = "issue"
    value = each.value
  }
}

resource "cloudflare_dns_record" "caa_issuewild" {
  for_each = var.manage_caa_records ? toset(var.caa_issuers) : toset([])

  zone_id = var.cloudflare_zone_id
  name    = data.cloudflare_zone.this[0].name
  type    = "CAA"
  ttl     = 3600

  data = {
    flags = 0
    tag   = "issuewild"
    value = each.value
  }
}

# Where a CA reports a request it refused because of the records above.
resource "cloudflare_dns_record" "caa_iodef" {
  count = var.manage_caa_records && var.caa_report_email != "" ? 1 : 0

  zone_id = var.cloudflare_zone_id
  name    = data.cloudflare_zone.this[0].name
  type    = "CAA"
  ttl     = 3600

  data = {
    flags = 0
    tag   = "iodef"
    value = "mailto:${var.caa_report_email}"
  }
}
