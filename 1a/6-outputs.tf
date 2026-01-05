# outputs.tf - Useful outputs for verification and testing

# -----------------------------------------------------------------------------
# EC2 Outputs
# -----------------------------------------------------------------------------
output "ec2_instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.web.id
}

output "ec2_public_ip" {
  description = "EC2 public IP address"
  value       = aws_instance.web.public_ip
}

output "ec2_public_dns" {
  description = "EC2 public DNS name"
  value       = aws_instance.web.public_dns
}

output "app_url" {
  description = "Base URL for the Notes application"
  value       = "http://${aws_instance.web.public_ip}"
}

output "app_endpoints" {
  description = "Application endpoint URLs"
  value = {
    init = "http://${aws_instance.web.public_ip}/init"
    add  = "http://${aws_instance.web.public_ip}/add?note=YOUR_NOTE_HERE"
    list = "http://${aws_instance.web.public_ip}/list"
  }
}

output "ssh_connection" {
  description = "SSH command to connect to EC2 instance"
  value       = "ssh -i ec2-ssh-key.pem ec2-user@${aws_instance.web.public_ip}"
}

output "ssh_private_key" {
  description = "SSH private key (save with: terraform output -raw ssh_private_key > ec2-ssh-key.pem && chmod 400 ec2-ssh-key.pem)"
  value       = tls_private_key.ec2_ssh.private_key_pem
  sensitive   = true
}

# -----------------------------------------------------------------------------
# RDS Outputs
# -----------------------------------------------------------------------------
output "rds_endpoint" {
  description = "RDS MySQL endpoint (host:port)"
  value       = aws_db_instance.mysql.endpoint
}

output "rds_address" {
  description = "RDS MySQL hostname"
  value       = aws_db_instance.mysql.address
}

output "rds_port" {
  description = "RDS MySQL port"
  value       = aws_db_instance.mysql.port
}

output "rds_identifier" {
  description = "RDS instance identifier"
  value       = aws_db_instance.mysql.identifier
}

# -----------------------------------------------------------------------------
# Secrets Manager Outputs
# -----------------------------------------------------------------------------
output "secret_arn" {
  description = "Secrets Manager secret ARN"
  value       = aws_secretsmanager_secret.db_credentials.arn
}

output "secret_name" {
  description = "Secrets Manager secret name"
  value       = aws_secretsmanager_secret.db_credentials.name
}

# -----------------------------------------------------------------------------
# Security Group Outputs
# -----------------------------------------------------------------------------
output "ec2_security_group_id" {
  description = "EC2 security group ID"
  value       = aws_security_group.ec2.id
}

output "rds_security_group_id" {
  description = "RDS security group ID"
  value       = aws_security_group.rds.id
}

# -----------------------------------------------------------------------------
# Network Outputs
# -----------------------------------------------------------------------------
output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = aws_subnet.private[*].id
}

# -----------------------------------------------------------------------------
# IAM Outputs
# -----------------------------------------------------------------------------
output "ec2_instance_profile_name" {
  description = "EC2 instance profile name"
  value       = aws_iam_instance_profile.ec2.name
}

output "ec2_iam_role_arn" {
  description = "EC2 IAM role ARN"
  value       = aws_iam_role.ec2.arn
}

# -----------------------------------------------------------------------------
# Verification Command Helpers
# -----------------------------------------------------------------------------
output "verification_commands" {
  description = "AWS CLI commands for verification"
  value = {
    check_instance       = "aws ec2 describe-instances --instance-ids ${aws_instance.web.id} --query 'Reservations[].Instances[].{State:State.Name,Profile:IamInstanceProfile.Arn}'"
    check_rds            = "aws rds describe-db-instances --db-instance-identifier ${aws_db_instance.mysql.identifier} --query 'DBInstances[].{Status:DBInstanceStatus,Endpoint:Endpoint}'"
    check_rds_sg         = "aws ec2 describe-security-group-rules --filter Name=group-id,Values=${aws_security_group.rds.id} --query 'SecurityGroupRules[?IsEgress==`false`]'"
    check_secret_from_sm = "aws secretsmanager get-secret-value --secret-id ${var.secret_name} --region ${var.aws_region}"
  }
}