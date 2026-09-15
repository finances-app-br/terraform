# The zone is shared with the platform stack in ../, which owns the zone-wide
# settings (SSL mode "strict", Always Use HTTPS, HSTS, DNSSEC, CAA) and the
# api/bff records. This stack owns the apex/www records and the zone's ruleset
# entrypoints below, with every rule scoped to the site's hostnames.
#
# Rulesets are zone *entrypoints*: Cloudflare allows one per phase per zone. A
# new rule in any of these phases — for any hostname, the API services included
# — goes into these resources, never into a second ruleset, the platform stack
# or the dashboard. If apply fails with "a similar configuration with rules
# already exists", a ruleset for that phase was created elsewhere: import it.

# Always proxied: the bucket policy only admits Cloudflare's IP ranges, so a
# DNS-only record would make the site unreachable.
resource "cloudflare_dns_record" "apex" {
  zone_id = var.cloudflare_zone_id
  name    = var.domain_name
  type    = "CNAME"
  content = aws_s3_bucket_website_configuration.site.website_endpoint
  ttl     = 1 # must be 1 (automatic) when proxied; the apex relies on CNAME flattening
  proxied = true
  comment = "Static site -> S3 website endpoint"
}

resource "cloudflare_dns_record" "www" {
  for_each = toset(local.www_hosts)

  zone_id = var.cloudflare_zone_id
  name    = each.value
  type    = "CNAME"
  content = var.domain_name
  ttl     = 1
  proxied = true
  comment = "www -> apex (301 via ruleset)"
}

# The zone SSL mode is "strict" for the API Gateway origins, but the S3 website
# endpoint has no HTTPS listener: without this override every site request
# would fail with 525/526. The browser leg is still HTTPS.
resource "cloudflare_ruleset" "config" {
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
      expression  = local.hosts_expression

      action_parameters = {
        ssl = "flexible"
      }
    },
  ]
}

resource "cloudflare_ruleset" "cache" {
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
      expression = "${local.apex_expression} and (${join(" or ", [for ext in ["css", "js", "mjs", "png", "jpg", "jpeg", "gif", "svg", "webp", "avif", "ico", "woff", "woff2", "ttf", "pdf"] : "ends_with(http.request.uri.path, \".${ext}\")"])})"

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
      expression  = "${local.apex_expression} and (ends_with(http.request.uri.path, \".html\") or ends_with(http.request.uri.path, \"/\"))"

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

# The HTTP -> HTTPS rule duplicates the zone's Always Use HTTPS on purpose: this
# stack can be applied before (or without) the platform stack that owns it.
resource "cloudflare_ruleset" "redirect" {
  zone_id     = var.cloudflare_zone_id
  name        = "Zone redirect rules"
  description = "Static site redirects: www to apex, HTTP to HTTPS"
  kind        = "zone"
  phase       = "http_request_dynamic_redirect"

  rules = concat(
    [
      for host in local.www_hosts : {
        action      = "redirect"
        description = "www -> apex"
        enabled     = true
        expression  = "(http.host eq \"${host}\")"

        action_parameters = {
          from_value = {
            status_code           = 301
            preserve_query_string = true

            target_url = {
              expression = "concat(\"https://${var.domain_name}\", http.request.uri.path)"
            }
          }
        }
      }
    ],
    [
      {
        action      = "redirect"
        description = "HTTP -> HTTPS on the apex"
        enabled     = true
        expression  = "${local.apex_expression} and not ssl"

        action_parameters = {
          from_value = {
            status_code           = 301
            preserve_query_string = true

            target_url = {
              expression = "concat(\"https://${var.domain_name}\", http.request.uri.path)"
            }
          }
        }
      },
    ],
  )
}

# HSTS and nosniff come zone-wide from the platform stack's security_header
# setting; these are the page-level headers only a website needs.
resource "cloudflare_ruleset" "response_headers" {
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
      expression  = local.hosts_expression

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
