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

  vpc_names_with_public = toset([
    for s in local.subnets : s.vpc_name
    if try(s.subnet.type, "private") == "public"
  ])

  vpc_names_with_private = toset([
    for s in local.subnets : s.vpc_name
    if try(s.subnet.type, "private") == "private"
  ])
}

resource "aws_vpc" "this" {
  for_each = var.vpcs

  cidr_block           = each.value.cidr_block
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(
    {
      Name = each.key
    },
    try(each.value.tags, {})
  )
}

resource "aws_subnet" "this" {
  for_each = local.subnets_by_key

  vpc_id                  = aws_vpc.this[each.value.vpc_name].id
  cidr_block              = each.value.subnet.cidr_block
  availability_zone       = each.value.subnet.availability_zone
  map_public_ip_on_launch = try(each.value.subnet.type, "private") == "public"

  tags = merge(
    {
      Name = each.value.subnet.name
      Tier = each.value.tier
      Type = try(each.value.subnet.type, "private")
    },
    try(each.value.subnet.tags, {}),
    try(var.vpcs[each.value.vpc_name].tags, {})
  )
}

resource "aws_internet_gateway" "this" {
  for_each = local.vpc_names_with_public

  vpc_id = aws_vpc.this[each.key].id

  tags = merge(
    {
      Name = "${each.key}-igw"
    },
    try(var.vpcs[each.key].tags, {})
  )
}

resource "aws_route_table" "public" {
  for_each = local.vpc_names_with_public

  vpc_id = aws_vpc.this[each.key].id

  tags = merge(
    {
      Name = "${each.key}-public-rt"
    },
    try(var.vpcs[each.key].tags, {})
  )
}

resource "aws_route" "public_internet" {
  for_each = local.vpc_names_with_public

  route_table_id         = aws_route_table.public[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this[each.key].id
}

resource "aws_route_table" "private" {
  for_each = local.vpc_names_with_private

  vpc_id = aws_vpc.this[each.key].id

  tags = merge(
    {
      Name = "${each.key}-private-rt"
    },
    try(var.vpcs[each.key].tags, {})
  )
}

resource "aws_route_table_association" "public" {
  for_each = {
    for k, s in local.subnets_by_key : k => s
    if try(s.subnet.type, "private") == "public"
  }

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.public[each.value.vpc_name].id
}

resource "aws_route_table_association" "private" {
  for_each = {
    for k, s in local.subnets_by_key : k => s
    if try(s.subnet.type, "private") == "private"
  }

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.private[each.value.vpc_name].id
}
