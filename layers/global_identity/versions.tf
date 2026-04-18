terraform {
  required_version = "= 1.11.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
    github = {
      source  = "integrations/github"
      version = ">= 6.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = ">= 4.0"
    }
  }
}
