terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }

  # State is kept apart from the platform stack in ../ on purpose: the site can
  # be planned, applied and destroyed without ever touching Aurora, Lambda or
  # API Gateway. Configure a remote backend for team use, e.g.:
  # backend "s3" {
  #   bucket       = "my-tf-state"
  #   key          = "finances-site/terraform.tfstate"
  #   region       = "us-east-1"
  #   use_lockfile = true
  # }
}
