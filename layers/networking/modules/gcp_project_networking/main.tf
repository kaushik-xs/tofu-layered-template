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

  # One Cloud Router + NAT per (VPC, region). Multiple subnets can share the same key — dedupe with toset.
  nat_region_keys = toset([
    for s in local.subnets : "${s.vpc_name}--${try(s.subnet.region, var.default_region)}"
  ])

  router_nat_instances = {
    for k in local.nat_region_keys : k => {
      vpc_name = [for s in local.subnets : s.vpc_name if "${s.vpc_name}--${try(s.subnet.region, var.default_region)}" == k][0]
      region   = try([for s in local.subnets : s if "${s.vpc_name}--${try(s.subnet.region, var.default_region)}" == k][0].subnet.region, var.default_region)
    }
  }

  router_nat_sorted_keys = sort(keys(local.router_nat_instances))

  # Each Cloud Router in a VPC must use a unique private ASN (64512–65534).
  router_bgp_asn = {
    for idx, k in local.router_nat_sorted_keys : k => 64512 + idx
  }
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

# Direct SSH (e.g. ansible-playbook -i '<public_ip>,'): source is your client IP, not IAP. Without this rule,
# only IAP-based SSH works when enable_iap_ssh_firewall is true. See variable ssh_ingress_source_ranges.
resource "google_compute_firewall" "ssh_ingress" {
  for_each = length(var.ssh_ingress_source_ranges) > 0 ? var.vpcs : {}

  name    = "${each.key}-allow-ssh-ingress"
  network = google_compute_network.this[each.key].name

  description = "Allow direct TCP 22 from configured CIDRs (not IAP); for Ansible or ssh user@public_ip."

  direction = "INGRESS"
  priority  = 1000

  source_ranges = var.ssh_ingress_source_ranges

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# Allow database traffic from the app (public) subnet to DB VMs in the private subnet.
# Scoped to VMs carrying db_target_tags so the rule does not apply network-wide.
resource "google_compute_firewall" "db_ingress" {
  for_each = length(var.db_ingress_source_ranges) > 0 ? var.vpcs : {}

  name    = "${each.key}-allow-db-ingress"
  network = google_compute_network.this[each.key].name

  description = "Allow TCP ${join(", ", var.db_ingress_ports)} from ${join(", ", var.db_ingress_source_ranges)} to VMs tagged: ${join(", ", var.db_target_tags)}."

  direction = "INGRESS"
  priority  = 1000

  source_ranges = var.db_ingress_source_ranges
  target_tags   = var.db_target_tags

  allow {
    protocol = "tcp"
    ports    = var.db_ingress_ports
  }
}

resource "google_compute_router" "nat" {
  for_each = var.enable_cloud_nat ? local.router_nat_instances : {}

  name    = "${each.value.vpc_name}-nat-router"
  region  = each.value.region
  network = google_compute_network.this[each.value.vpc_name].id

  bgp {
    asn = local.router_bgp_asn[each.key]
  }
}

resource "google_compute_router_nat" "this" {
  for_each = var.enable_cloud_nat ? local.router_nat_instances : {}

  name   = "${each.value.vpc_name}-nat"
  router = google_compute_router.nat[each.key].name
  region = google_compute_router.nat[each.key].region

  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
