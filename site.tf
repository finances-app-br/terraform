# Static marketing site (landing + institutional pages) served at the zone
# apex. The HTML/CSS/JS lives in the `site` repository, whose GitHub Actions
# workflow builds it and syncs it into this bucket through the deploy role in
# iam.tf — Terraform never uploads content.
#
# Cloudflare proxies requests to the S3 *website* endpoint with the original
# Host header, and S3 routes website requests by hostname, so the bucket name
# must be exactly site_domain_name. The website endpoint speaks plain HTTP
# only, which is why cloudflare.tf lowers SSL to "flexible" for these hosts.

data "cloudflare_ip_ranges" "cloudflare" {
  count = local.site_enabled ? 1 : 0
}

resource "aws_s3_bucket" "site" {
  count = local.site_enabled ? 1 : 0

  bucket = var.site_domain_name
}

resource "aws_s3_bucket_ownership_controls" "site" {
  count = local.site_enabled ? 1 : 0

  bucket = aws_s3_bucket.site[0].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# ACLs stay blocked; only the bucket policy below may grant read access.
resource "aws_s3_bucket_public_access_block" "site" {
  count = local.site_enabled ? 1 : 0

  bucket = aws_s3_bucket.site[0].id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_versioning" "site" {
  count = local.site_enabled ? 1 : 0

  bucket = aws_s3_bucket.site[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "site" {
  count = local.site_enabled ? 1 : 0

  bucket = aws_s3_bucket.site[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# The index document is what makes pretty URLs work: /contato/ is served from
# contato/index.html, and /contato gets a 302 to /contato/.
resource "aws_s3_bucket_website_configuration" "site" {
  count = local.site_enabled ? 1 : 0

  bucket = aws_s3_bucket.site[0].id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "index.html"
  }
}

# Reads are allowed only from Cloudflare's edge ranges. Opening this up would
# let anyone hit the website endpoint directly and bypass every edge rule
# (cache, redirects, headers).
data "aws_iam_policy_document" "site_bucket" {
  count = local.site_enabled ? 1 : 0

  statement {
    sid       = "AllowCloudflareEdgeRead"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site[0].arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "IpAddress"
      variable = "aws:SourceIp"
      values = concat(
        data.cloudflare_ip_ranges.cloudflare[0].ipv4_cidrs,
        data.cloudflare_ip_ranges.cloudflare[0].ipv6_cidrs,
      )
    }
  }
}

resource "aws_s3_bucket_policy" "site" {
  count = local.site_enabled ? 1 : 0

  bucket = aws_s3_bucket.site[0].id
  policy = data.aws_iam_policy_document.site_bucket[0].json

  depends_on = [aws_s3_bucket_public_access_block.site]
}
