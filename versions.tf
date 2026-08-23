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
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.6"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }

  # Configure a remote backend for team use, e.g.:
  # backend "s3" {
  #   bucket       = "my-tf-state"
  #   key          = "finance-app-bff/terraform.tfstate"
  #   region       = "us-east-1"
  #   use_lockfile = true
  # }
}
