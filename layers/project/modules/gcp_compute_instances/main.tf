locals {
  instances = var.instances
}

resource "google_compute_instance" "this" {
  for_each = local.instances

  name         = try(each.value.name, each.key)
  machine_type = try(each.value.machine_type, "e2-medium")
  zone         = try(each.value.zone, var.default_zone)

  boot_disk {
    initialize_params {
      image = try(each.value.boot_disk_image, "projects/debian-cloud/global/images/family/debian-12")
      size  = try(each.value.boot_disk_size_gb, 20)
      type  = try(each.value.boot_disk_type, "pd-balanced")
    }
  }

  network_interface {
    subnetwork = var.subnetwork_ids[each.value.subnet_key]
    network_ip = try(each.value.private_ip, null)
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
  }
}
