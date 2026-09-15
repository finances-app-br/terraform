# Static marketing site (landing + institutional pages). The HTML/CSS/JS lives
# in the `site` repository, whose GitHub Actions workflow builds it and syncs it
# into this bucket through the deploy role in iam.tf — Terraform never uploads
# content.
#
# Cloudflare proxies requests to the S3 *website* endpoint with the original
# Host header, and S3 routes website requests by hostname, so the bucket name
# must be exactly domain_name. The website endpoint speaks plain HTTP only,
# which is why cloudflare.tf lowers SSL to "flexible" for these hosts.

data "cloudflare_ip_ranges" "cloudflare" {}

resource "aws_s3_bucket" "site" {
  bucket = var.domain_name
}

resource "aws_s3_bucket_ownership_controls" "site" {
  bucket = aws_s3_bucket.site.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# ACLs stay blocked; only the bucket policy below may grant read access.
resource "aws_s3_bucket_public_access_block" "site" {
  bucket = aws_s3_bucket.site.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_versioning" "site" {
  bucket = aws_s3_bucket.site.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "site" {
  bucket = aws_s3_bucket.site.id

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
  bucket = aws_s3_bucket.site.id

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
data "aws_iam_policy_document" "bucket" {
  statement {
    sid       = "AllowCloudflareEdgeRead"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "IpAddress"
      variable = "aws:SourceIp"
      values = concat(
        data.cloudflare_ip_ranges.cloudflare.ipv4_cidrs,
        data.cloudflare_ip_ranges.cloudflare.ipv6_cidrs,
      )
    }
  }
}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = data.aws_iam_policy_document.bucket.json

  depends_on = [aws_s3_bucket_public_access_block.site]
}
