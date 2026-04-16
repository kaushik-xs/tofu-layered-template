terraform {
  backend "s3" {
    bucket = "tofu-regere-backend-1236879"
    key     = "global_identity_layer/secrets/terraform.tfstate"
    region  = "ap-south-1"
    encrypt = true
  }
}
