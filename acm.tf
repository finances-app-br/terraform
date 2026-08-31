# Regional ACM certificate per service domain, validated via the
# Cloudflare-managed DNS zone. The cert must live in the same region as the
# regional custom domain (the default provider region).
resource "aws_acm_certificate" "service" {
  for_each = local.domain_services

  domain_name       = each.value.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate_validation" "service" {
  for_each = local.domain_services

  certificate_arn         = aws_acm_certificate.service[each.key].arn
  validation_record_fqdns = [cloudflare_dns_record.cert_validation[each.key].name]
}
