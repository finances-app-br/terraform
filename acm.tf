# Regional ACM certificate for the API Gateway custom domain, validated via the
# Cloudflare-managed DNS zone. The cert must live in the same region as the
# regional custom domain (the default provider region).
resource "aws_acm_certificate" "this" {
  count             = local.custom_domain_enabled
  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate_validation" "this" {
  count                   = local.custom_domain_enabled
  certificate_arn         = aws_acm_certificate.this[0].arn
  validation_record_fqdns = [cloudflare_dns_record.cert_validation[0].name]
}
