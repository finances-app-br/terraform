provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.tags
  }
}

provider "cloudflare" {
  # null (not "") leaves the attribute unset, which is what lets the provider
  # fall back to the CLOUDFLARE_API_TOKEN environment variable.
  api_token = var.cloudflare_api_token != "" ? var.cloudflare_api_token : null
}
