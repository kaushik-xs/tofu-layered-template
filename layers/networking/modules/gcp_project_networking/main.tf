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

# IAP for TCP (SSH): ingress from Google's IAP proxy range. Required for
# `gcloud compute ssh --tunnel-through-iap` and browser-based SSH when the VM has no public IP
# or when routing through IAP. See https://cloud.google.com/iap/docs/using-tcp-forwarding#create-firewall-rule
resource "google_compute_firewall" "iap_ssh" {
  for_each = var.enable_iap_ssh_firewall ? var.vpcs : {}

  name    = "${each.key}-allow-iap-ssh"
  network = google_compute_network.this[each.key].name

  description = "Allow IAP TCP forwarding to SSH (35.235.240.0/20 -> tcp/22)."

  direction = "INGRESS"
  priority  = 1000

  source_ranges = ["35.235.240.0/20"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}
