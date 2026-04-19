locals {
  instances = var.instances

  # Default OS image when boot_disk_image is not set. ubuntu-server-lts uses the Ubuntu 24.04 LTS family on GCP.
  gcp_boot_image_debian12   = "projects/debian-cloud/global/images/family/debian-12"
  gcp_boot_image_ubuntu_lts = "projects/ubuntu-os-cloud/global/images/family/ubuntu-2404-lts-amd64"
}

resource "google_compute_instance" "this" {
  for_each = local.instances

  name         = try(each.value.name, each.key)
  machine_type = try(each.value.machine_type, "e2-medium")
  zone         = try(each.value.zone, var.default_zone)

  boot_disk {
    initialize_params {
      image = (
        try(each.value.boot_disk_image, null) != null && trimspace(tostring(each.value.boot_disk_image)) != "" ?
        each.value.boot_disk_image :
        try(each.value.os, "debian-12") == "ubuntu-server-lts" ? local.gcp_boot_image_ubuntu_lts : local.gcp_boot_image_debian12
      )
      size = try(each.value.boot_disk_size_gb, 20)
      type = try(each.value.boot_disk_type, "pd-balanced")
    }
  }

  network_interface {
    subnetwork = var.subnetwork_ids[each.value.subnet_key]
    network_ip = try(each.value.private_ip, null)

    dynamic "access_config" {
      for_each = (
        try(each.value.external_static_ip_key, null) != null &&
        trimspace(tostring(each.value.external_static_ip_key)) != ""
      ) ? [1] : []

      content {
        nat_ip = var.regional_external_addresses[each.value.external_static_ip_key]
      }
    }
  }

  dynamic "service_account" {
    for_each = try(each.value.service_account_email, null) != null ? [1] : []

    content {
      email  = each.value.service_account_email
      scopes = try(each.value.service_account_scopes, ["https://www.googleapis.com/auth/cloud-platform"])
    }
  }

  metadata = merge(
    try(each.value.vpc_name, null) != null ? { vpc = each.value.vpc_name } : {},
    try(each.value.network_name, null) != null ? { network = each.value.network_name } : {},
    try(each.value.metadata, {})
  )

  labels = try(each.value.labels, {})

  lifecycle {
    precondition {
      condition     = contains(keys(var.subnetwork_ids), each.value.subnet_key)
      error_message = "subnet_key must exist in subnetwork_ids from networking state."
    }
    precondition {
      condition = (
        try(each.value.external_static_ip_key, null) == null ||
        trimspace(tostring(try(each.value.external_static_ip_key, ""))) == "" ||
        contains(keys(var.regional_external_addresses), each.value.external_static_ip_key)
      )
      error_message = "external_static_ip_key must exist in regional_external_addresses (networking gcp_external_static_ips.regional_addresses)."
    }
  }
}

resource "null_resource" "instance_local_exec" {
  for_each = {
    for k, v in local.instances : k => v
    if trimspace(try(v.local_exec.command, "")) != ""
  }

  provisioner "local-exec" {
    # Run from the layer root (e.g. layers/project_data) so paths like ../../playbooks match terraform.tfvars examples.
    working_dir = path.root

    command = templatestring(each.value.local_exec.command, merge(
      try(each.value.local_exec.template_vars, {}),
      {
        public_ip   = try(google_compute_instance.this[each.key].network_interface[0].access_config[0].nat_ip, "")
        nat_ip      = try(google_compute_instance.this[each.key].network_interface[0].access_config[0].nat_ip, "")
        private_ip  = google_compute_instance.this[each.key].network_interface[0].network_ip
        name        = try(each.value.name, each.key)
        zone        = try(each.value.zone, var.default_zone)
        region      = var.region
        instance_id = google_compute_instance.this[each.key].instance_id
        ansible_user = (
          try(each.value.ansible_user, null) != null && trimspace(tostring(each.value.ansible_user)) != "" ?
          trimspace(tostring(each.value.ansible_user)) :
          try(each.value.os, "debian-12") == "ubuntu-server-lts" ? "ubuntu" : "debian"
        )
      }
    ))
  }
}
