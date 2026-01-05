# security_groups.tf - Security groups for EC2 and RDS
#
# Security model:
# - EC2 SG: Allows HTTP from configurable CIDRs, optional SSH from restricted CIDR
# - RDS SG: Allows MySQL (3306) ONLY from EC2 security group (SG-to-SG reference)
# - Using standalone rules (aws_vpc_security_group_*_rule) per AWS provider 5.x best practices

# -----------------------------------------------------------------------------
# EC2 Security Group
# -----------------------------------------------------------------------------
resource "aws_security_group" "ec2" {
  name        = "${local.name_prefix}-ec2-sg"
  description = "Security group for EC2 web application instance"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-ec2-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# EC2 Inbound: HTTP from allowed CIDRs
resource "aws_vpc_security_group_ingress_rule" "ec2_http" {
  for_each = toset(var.allowed_http_cidrs)

  security_group_id = aws_security_group.ec2.id
  description       = "HTTP from ${each.value}"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = each.value

  tags = {
    Name = "${local.name_prefix}-ec2-http-${replace(each.value, "/", "-")}"
  }
}

# EC2 Inbound: SSH from restricted CIDR (conditional)
resource "aws_vpc_security_group_ingress_rule" "ec2_ssh" {
  count = local.ssh_enabled ? 1 : 0

  security_group_id = aws_security_group.ec2.id
  description       = "SSH from ${var.ssh_allowed_cidr}"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = var.ssh_allowed_cidr

  tags = {
    Name = "${local.name_prefix}-ec2-ssh"
  }
}

# EC2 Outbound: All traffic (required for package installation and AWS API calls)
resource "aws_vpc_security_group_egress_rule" "ec2_all_outbound" {
  security_group_id = aws_security_group.ec2.id
  description       = "All outbound traffic"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"

  tags = {
    Name = "${local.name_prefix}-ec2-outbound"
  }
}

# -----------------------------------------------------------------------------
# RDS Security Group
# -----------------------------------------------------------------------------
resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds-sg"
  description = "Security group for RDS MySQL - allows access only from EC2 SG"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-rds-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# RDS Inbound: MySQL from EC2 security group only (SG-to-SG reference)
# This is the key security pattern: no CIDR, only trusted SG reference
resource "aws_vpc_security_group_ingress_rule" "rds_mysql_from_ec2" {
  security_group_id = aws_security_group.rds.id
  description       = "MySQL from EC2 security group"
  ip_protocol       = "tcp"
  from_port         = var.db_port
  to_port           = var.db_port

  # SG-to-SG reference - this is the critical security pattern
  referenced_security_group_id = aws_security_group.ec2.id

  tags = {
    Name = "${local.name_prefix}-rds-mysql-from-ec2"
  }
}

# RDS has no egress rules - it doesn't need outbound internet access