# locals.tf - Local values for repeated references and computed values

locals {
  # Naming prefix for all resources
  name_prefix = var.project_name

  # Common tags applied to resources (in addition to provider default_tags)
  common_tags = {
    Lab = "EC2-RDS-Notes"
  }

  # Availability zones - use first two in the region
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # Subnet CIDR calculations
  public_subnet_cidrs  = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 8, i)]
  private_subnet_cidrs = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 100)]

  # SSH enabled flag
  ssh_enabled = var.ssh_allowed_cidr != ""

  # Secret JSON structure - populated after RDS creation
  db_secret = {
    username = var.db_username
    password = random_password.db_password.result
    host     = aws_db_instance.mysql.address
    port     = var.db_port
    dbname   = var.db_name
  }
}

# Data source to get available AZs
data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# Data source to get latest Amazon Linux 2023 AMI
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}
