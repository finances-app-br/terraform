# DNS record that proves domain ownership to ACM.
resource "cloudflare_dns_record" "cert_validation" {
  count   = local.custom_domain_enabled
  zone_id = var.cloudflare_zone_id
  name    = trimsuffix(tolist(aws_acm_certificate.this[0].domain_validation_options)[0].resource_record_name, ".")
  type    = tolist(aws_acm_certificate.this[0].domain_validation_options)[0].resource_record_type
  content = trimsuffix(tolist(aws_acm_certificate.this[0].domain_validation_options)[0].resource_record_value, ".")
  ttl     = 60
  proxied = false # validation records must resolve directly to AWS
}

# Public record clients hit. Proxied so Cloudflare fronts the API Gateway custom
# domain (set the zone's SSL/TLS mode to "Full" so the proxy trusts the AWS cert).
resource "cloudflare_dns_record" "api" {
  count   = local.custom_domain_enabled
  zone_id = var.cloudflare_zone_id
  name    = var.domain_name
  type    = "CNAME"
  content = aws_apigatewayv2_domain_name.this[0].domain_name_configuration[0].target_domain_name
  ttl     = 1 # must be 1 (automatic) when proxied
  proxied = var.cloudflare_proxied
}
