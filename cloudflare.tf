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

# ------------------------------------------------------------ static site ---
#
# The apex (and www) serve the S3 website from site.tf. Every rule below is
# scoped to the site's hostnames, so api/bff keep their own behaviour.
#
# Rulesets are zone *entrypoints*: Cloudflare allows one per phase per zone. Any
# future rule in these phases — for any hostname, including the API services —
# has to be added to these resources, never to a second ruleset or the
# dashboard. If apply fails with "a similar configuration with rules already
# exists", a ruleset for that phase was created elsewhere: import it first.

# Always proxied: the bucket policy only admits Cloudflare's IP ranges, so a
# DNS-only record would make the site unreachable.
resource "cloudflare_dns_record" "site_apex" {
  count = local.site_enabled ? 1 : 0

  zone_id = var.cloudflare_zone_id
  name    = var.site_domain_name
  type    = "CNAME"
  content = aws_s3_bucket_website_configuration.site[0].website_endpoint
  ttl     = 1 # must be 1 (automatic) when proxied; the apex relies on CNAME flattening
  proxied = true
  comment = "Static site -> S3 website endpoint"
}

resource "cloudflare_dns_record" "site_www" {
  count = local.site_enabled && var.site_www_redirect ? 1 : 0

  zone_id = var.cloudflare_zone_id
  name    = "www.${var.site_domain_name}"
  type    = "CNAME"
  content = var.site_domain_name
  ttl     = 1
  proxied = true
  comment = "www -> apex (301 via ruleset)"
}

# The zone SSL mode stays "strict" for the API Gateway origins, but the S3
# website endpoint has no HTTPS listener: without this override every site
# request would fail with 525/526. The browser leg is still HTTPS.
resource "cloudflare_ruleset" "config" {
  count = local.site_enabled ? 1 : 0

  zone_id     = var.cloudflare_zone_id
  name        = "Zone configuration rules"
  description = "Per-host overrides of zone settings"
  kind        = "zone"
  phase       = "http_config_settings"

  rules = [
    {
      action      = "set_config"
      description = "SSL flexible for the static site (S3 website endpoint is HTTP-only)"
      enabled     = true
      expression  = local.site_hosts_expression

      action_parameters = {
        ssl = "flexible"
      }
    },
  ]
}

resource "cloudflare_ruleset" "cache" {
  count = local.site_enabled ? 1 : 0

  zone_id     = var.cloudflare_zone_id
  name        = "Zone cache rules"
  description = "Long TTL for the site's hashed assets, short TTL for its pages"
  kind        = "zone"
  phase       = "http_request_cache_settings"

  rules = [
    {
      action      = "set_cache_settings"
      description = "Static site assets (content-hashed by the build): 30 days"
      enabled     = true
      # `matches` (regex) needs the Business plan; ends_with works on Free.
      expression = "${local.site_apex_expression} and (${join(" or ", [for ext in ["css", "js", "mjs", "png", "jpg", "jpeg", "gif", "svg", "webp", "avif", "ico", "woff", "woff2", "ttf", "pdf"] : "ends_with(http.request.uri.path, \".${ext}\")"])})"

      action_parameters = {
        cache = true

        edge_ttl = {
          mode    = "override_origin"
          default = 2592000
        }

        browser_ttl = {
          mode    = "override_origin"
          default = 2592000
        }
      }
    },
    {
      action      = "set_cache_settings"
      description = "Static site pages (.html and directory URLs such as /contato/): 1 h edge, 5 min browser"
      enabled     = true
      expression  = "${local.site_apex_expression} and (ends_with(http.request.uri.path, \".html\") or ends_with(http.request.uri.path, \"/\"))"

      action_parameters = {
        cache = true

        edge_ttl = {
          mode    = "override_origin"
          default = 3600
        }

        browser_ttl = {
          mode    = "override_origin"
          default = 300
        }
      }
    },
  ]
}

resource "cloudflare_ruleset" "redirect" {
  count = local.site_enabled && var.site_www_redirect ? 1 : 0

  zone_id     = var.cloudflare_zone_id
  name        = "Zone redirect rules"
  description = "301 from www.${var.site_domain_name} to the apex"
  kind        = "zone"
  phase       = "http_request_dynamic_redirect"

  rules = [
    {
      action      = "redirect"
      description = "www -> apex"
      enabled     = true
      expression  = "(http.host eq \"www.${var.site_domain_name}\")"

      action_parameters = {
        from_value = {
          status_code           = 301
          preserve_query_string = true

          target_url = {
            expression = "concat(\"https://${var.site_domain_name}\", http.request.uri.path)"
          }
        }
      }
    },
  ]
}

# HSTS and nosniff come zone-wide from cloudflare_zone_setting.security_header;
# these are the page-level headers only a website needs.
resource "cloudflare_ruleset" "response_headers" {
  count = local.site_enabled ? 1 : 0

  zone_id     = var.cloudflare_zone_id
  name        = "Zone response header rules"
  description = "Browser security headers for the static site"
  kind        = "zone"
  phase       = "http_response_headers_transform"

  rules = [
    {
      action      = "rewrite"
      description = "Static site security headers"
      enabled     = true
      expression  = local.site_hosts_expression

      action_parameters = {
        headers = {
          "X-Frame-Options" = {
            operation = "set"
            value     = "SAMEORIGIN"
          }
          "Referrer-Policy" = {
            operation = "set"
            value     = "strict-origin-when-cross-origin"
          }
          "Permissions-Policy" = {
            operation = "set"
            value     = "camera=(), microphone=(), geolocation=()"
          }
        }
      }
    },
  ]
}
