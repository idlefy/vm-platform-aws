# Every resource here sets `region` explicitly rather than inheriting it from the
# provider. That is what lets the root module instantiate this one with `for_each`
# over local.regions against a *single* provider: provider blocks cannot be
# generated, and `providers = {}` in a module call cannot be dynamic, so aliased
# providers would force one hand-written pair of blocks per region. Per-resource
# `region` arrived in AWS provider v6, which this repo pins.
#
# Global resources (IAM, Route53) have no `region` argument and take none.

resource "aws_vpc" "this" {
  region               = var.aws_region
  cidr_block           = var.network_config.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.default_tags, {
    Name = "${var.environment}-ec2-vpc"
  })
}

resource "aws_internet_gateway" "this" {
  region = var.aws_region
  vpc_id = aws_vpc.this.id

  tags = merge(local.default_tags, {
    Name = "${var.environment}-ec2-igw"
  })
}

resource "aws_subnet" "public" {
  for_each = var.network_config.public_subnets

  region                  = var.aws_region
  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr_block
  availability_zone       = each.value.az
  map_public_ip_on_launch = true

  tags = merge(local.default_tags, {
    Name = "${var.environment}-ec2-${each.key}"
  })
}

resource "aws_route_table" "public" {
  region = var.aws_region
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(local.default_tags, {
    Name = "${var.environment}-ec2-public-rt"
  })
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  region         = var.aws_region
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

locals {
  subnet_ids = { for k, v in aws_subnet.public : k => v.id }
}
