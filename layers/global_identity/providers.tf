provider "aws" {
  region = var.aws_region
}

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}

provider "github" {
  owner = var.github_owner
  token = var.github_token
}

provider "vault" {
  address = var.vault_address
  token   = var.vault_token
}
