# Shared SSH key pair for AWS compute, generated once here so the public-subnet bastion (project layer) and
# the private-subnet VMs (project_data layer) all authenticate with the SAME key. That single key lets you SSH
# the bastion and then jump (ProxyJump / agent-forward) to the private VMs. Both consuming layers read the key
# name from this layer's remote state; nobody recreates it.
#
# Created only when var.aws_compute_key_pair_name is set, so a GCP-only networking deploy needs no AWS key/creds.
# The private key is exported (sensitive) below for operators to write to a local 0600 file.
locals {
  aws_compute_key_enabled = trimspace(var.aws_compute_key_pair_name) != ""
}

resource "tls_private_key" "compute" {
  count     = local.aws_compute_key_enabled ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "compute" {
  count      = local.aws_compute_key_enabled ? 1 : 0
  key_name   = var.aws_compute_key_pair_name
  public_key = tls_private_key.compute[0].public_key_openssh
}
