resource "google_compute_address" "regional_external" {
  for_each = var.regional_external_addresses

  name    = each.key
  project = var.project_id
  region  = try(each.value.region, var.default_region)

  address_type = "EXTERNAL"
  ip_version   = upper(try(each.value.ip_version, "IPV4"))

  description = try(each.value.description, null)
  network_tier = try(each.value.network_tier, null) != null ? upper(each.value.network_tier) : null
}

resource "google_compute_global_address" "global_external" {
  for_each = var.global_external_addresses

  name    = each.key
  project = var.project_id

  address_type = "EXTERNAL"
  ip_version   = upper(try(each.value.ip_version, "IPV4"))

  description = try(each.value.description, null)
}
