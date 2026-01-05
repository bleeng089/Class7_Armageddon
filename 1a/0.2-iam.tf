# iam.tf - IAM role and policies for EC2 instance
#
# Least-privilege policy grants:
# - secretsmanager:GetSecretValue on the specific secret ARN only
# - No KMS permissions needed (using AWS-managed key)

# IAM policy document for EC2 assume role
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    sid     = "EC2AssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# IAM role for EC2 instances
resource "aws_iam_role" "ec2" {
  name               = "${local.name_prefix}-ec2-role"
  description        = "IAM role for EC2 instances to access Secrets Manager"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-ec2-role"
  })
}

# IAM policy document for Secrets Manager access - least privilege
data "aws_iam_policy_document" "secrets_access" {
  statement {
    sid    = "GetDBSecret"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue"
    ]
    # Scoped to the specific secret ARN only
    resources = [aws_secretsmanager_secret.db_credentials.arn]
  }
}

# IAM policy for Secrets Manager access
resource "aws_iam_policy" "secrets_access" {
  name        = "${local.name_prefix}-secrets-access"
  description = "Allow EC2 to read database credentials from Secrets Manager"
  policy      = data.aws_iam_policy_document.secrets_access.json

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-secrets-access"
  })
}

# Attach secrets access policy to EC2 role
resource "aws_iam_role_policy_attachment" "secrets_access" {
  role       = aws_iam_role.ec2.name
  policy_arn = aws_iam_policy.secrets_access.arn
}

# Instance profile to attach role to EC2
resource "aws_iam_instance_profile" "ec2" {
  name = "${local.name_prefix}-ec2-profile"
  role = aws_iam_role.ec2.name

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-ec2-profile"
  })
}