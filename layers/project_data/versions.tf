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
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0"
    }
  }
}
