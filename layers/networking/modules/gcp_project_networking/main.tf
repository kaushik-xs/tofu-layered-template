locals {
  subnets = flatten([
    for vpc_name, vpc in var.vpcs : [
      for tier_name, subnet_list in try(vpc.subnets, {}) : [
        for s in subnet_list : {
          key      = "${vpc_name}-${tier_name}-${s.name}"
          vpc_name = vpc_name
          tier     = tier_name
          subnet   = s
        }
      ]
    ]
  ])

  subnets_by_key = { for s in local.subnets : s.key => s }
}

resource "google_compute_network" "this" {
  for_each = var.vpcs

  name                    = each.key
  auto_create_subnetworks = false
  routing_mode            = upper(try(each.value.routing_mode, "REGIONAL"))
}

resource "google_compute_subnetwork" "this" {
  for_each = local.subnets_by_key

  name          = each.value.subnet.name
  ip_cidr_range = each.value.subnet.cidr_block
  region        = try(each.value.subnet.region, var.default_region)
  network       = google_compute_network.this[each.value.vpc_name].id

  private_ip_google_access = try(each.value.subnet.private_access, false)
}
