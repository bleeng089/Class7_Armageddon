# Security Considerations

## Overview

This lab implements automatic SSH key pair generation using the `tls_private_key` Terraform resource. While convenient for learning environments, this approach has **important security implications** that users must understand before use in production.

---

## Critical Security Warning

### SSH Private Key Storage in Terraform State

**The generated SSH private key is stored in your Terraform state file.**

This means:
- ✅ If your backend is properly secured (encrypted S3 with restricted IAM), the key is protected at rest
- ⚠️ Anyone with access to your Terraform state can extract the private key
- ⚠️ State file access = SSH access to your EC2 instances

### Backend Security Requirements

**You MUST use a secure remote backend with encryption:**

```hcl
# Example: Encrypted S3 backend (recommended)
terraform {
  backend "s3" {
    bucket         = "your-terraform-state-bucket"
    key            = "lab-1a/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true                    # Enable server-side encryption
    kms_key_id     = "arn:aws:kms:..."      # Use KMS for encryption (recommended)
    dynamodb_table = "terraform-lock-table" # Enable state locking
  }
}
```

**Never use local backend (`terraform.tfstate` file) with sensitive credentials in production.**

---

## The Biggest Risk: Extracting Keys to Disk

### The Command

```bash
terraform output -raw ssh_private_key > ec2-ssh-key.pem && chmod 400 ec2-ssh-key.pem
```

### Why This Is Dangerous

When you run this command, you are:
1. **Extracting a secret from secure storage** (encrypted S3 backend)
2. **Writing it to your local filesystem** (unencrypted, typically)
3. **Creating a security dependency on two things:**
   - **`.gitignore`** - Must correctly exclude `*.pem` files
   - **Your memory** - You must remember not to commit it

### The Threat Model

| Attack Vector | Risk Level | Description |
|--------------|------------|-------------|
| **Accidental Git commit** | 🔴 **CRITICAL** | User forgets `.gitignore` or uses `git add -f` |
| **IDE auto-commit** | 🔴 **CRITICAL** | Some IDEs auto-stage new files |
| **Filesystem backup** | 🟡 **MEDIUM** | Local backups may include unencrypted keys |
| **Shared workstation** | 🟡 **MEDIUM** | Other users with filesystem access can read the key |
| **Malware/ransomware** | 🟡 **MEDIUM** | Local filesystem exposure |
| **Terraform state access** | 🟢 **LOW** | Requires AWS credentials + S3 access (if backend secured) |

**The key moves from "protected by IAM + KMS + S3 bucket policy" to "protected by .gitignore and hope."**

---

## What Makes This a Concern

### 1. Gitignore Is Not Foolproof

The `.gitignore` file in this project contains:

```gitignore
# SSH Keys
ec2-ssh-key.pem
*.pem
```

**However:**
- Users can bypass with `git add -f ec2-ssh-key.pem`
- If the file is committed before `.gitignore` is created, it's tracked forever (even after deletion)
- Not all users read `.gitignore` before committing
- Some Git GUIs make it easy to accidentally include ignored files

### 2. Human Error Is Common

Real-world scenarios:
- Developer forgets they saved the key locally
- Months later, runs `git add .` without checking `git status` carefully
- Key is committed, pushed, and now in repository history forever
- Even after `git rm`, key remains in Git history unless force-pushed (which breaks others' clones)

### 3. Once Committed, It's Permanent

If the private key is pushed to a Git repository:
- **It's in the Git history permanently** (even if deleted in later commits)
- **Requires force push to remove** - breaks all team members' local repos
- **May be cloned by many users** - impossible to know who has a copy
- **GitHub/GitLab/etc may cache it** - out of your control
- **Automated scanners** (GitHub secret scanning) will flag it, but damage is done

---

## Best Practices

### For Learning Environments (This Lab)

✅ **Acceptable:**
- Using this approach for short-lived lab infrastructure
- Destroying resources with `terraform destroy` after learning
- Not using production data or production AWS accounts

⚠️ **Required:**
- Use encrypted S3 backend with KMS encryption
- Restrict S3 bucket access with IAM policies
- Enable S3 bucket versioning (allows state recovery)
- **Only extract the key when absolutely necessary**
- Delete `ec2-ssh-key.pem` immediately after use: `rm ec2-ssh-key.pem`
- Never commit the Terraform state file to version control

### For Production Environments

🔴 **DO NOT use this approach in production.** Use one of these alternatives:

#### Alternative 1: AWS Systems Manager Session Manager (Recommended)
```hcl
# No SSH key needed - uses IAM for authentication
# Requires: SSM agent (pre-installed on Amazon Linux 2023)
```

**Connect without SSH keys:**
```bash
aws ssm start-session --target $(terraform output -raw ec2_instance_id)
```

**Benefits:**
- No SSH keys to manage
- Authentication via IAM
- Centralized access logging in CloudTrail
- No open SSH port (22) required in security group
- No key material in Terraform state

#### Alternative 2: Pre-Created AWS Key Pair
```hcl
variable "key_name" {
  description = "Pre-existing AWS key pair name"
  type        = string
}

resource "aws_instance" "web" {
  key_name = var.key_name  # Reference existing key pair
  # ...
}
```

**Benefits:**
- Private key never touches Terraform state
- Users manage their own keys separately
- Key rotation independent of infrastructure

#### Alternative 3: AWS Secrets Manager for SSH Keys
```hcl
# Store pre-generated SSH private key in Secrets Manager
# EC2 retrieves public key from Secrets Manager during boot
# Users retrieve private key from Secrets Manager (not Terraform)
```

**Benefits:**
- IAM-controlled access to private key
- Automatic key rotation support
- Audit trail via CloudTrail
- Separation from Terraform state

---

## Risk Assessment Matrix

### Using This Lab's Approach

| Security Control | Protection Level | Notes |
|-----------------|------------------|-------|
| **State encryption** | 🟢 **STRONG** | If using encrypted S3 + KMS |
| **State access control** | 🟢 **STRONG** | If using IAM policies correctly |
| **Key on disk protection** | 🔴 **WEAK** | Relies on `.gitignore` + user awareness |
| **Accidental exposure** | 🔴 **HIGH RISK** | One `git add -f` away from disaster |
| **Audit trail** | 🟡 **MEDIUM** | CloudTrail logs S3 access, not local file operations |

### Using Systems Manager Session Manager

| Security Control | Protection Level | Notes |
|-----------------|------------------|-------|
| **No secrets in state** | 🟢 **STRONG** | No SSH keys at all |
| **Authentication** | 🟢 **STRONG** | IAM-based, MFA-capable |
| **Key on disk protection** | 🟢 **N/A** | No keys to protect |
| **Accidental exposure** | 🟢 **ELIMINATED** | Nothing to expose |
| **Audit trail** | 🟢 **STRONG** | Full CloudTrail logging |

---

## Security Checklist

Before using this lab:

- [ ] Using encrypted remote backend (S3 + KMS or Terraform Cloud)?
- [ ] S3 bucket has restricted IAM policies (least privilege)?
- [ ] S3 bucket versioning enabled?
- [ ] Understand that private key is in Terraform state?
- [ ] Verified `.gitignore` includes `*.pem`?
- [ ] Comfortable with the risks of extracting key to disk?
- [ ] Will remember to delete `ec2-ssh-key.pem` after use?
- [ ] Using a non-production AWS account?
- [ ] Plan to run `terraform destroy` when done?

Before extracting the SSH key:

- [ ] Actually need SSH access (vs using AWS Systems Manager)?
- [ ] Checked that `.gitignore` exists and includes `*.pem`?
- [ ] Will delete the key file immediately after use?
- [ ] Verified Git status before next commit?

---

## Incident Response

### If You Accidentally Commit the Private Key

**DO THIS IMMEDIATELY:**

1. **Rotate the key** (regenerate):
   ```bash
   # This will create a new key pair
   terraform taint tls_private_key.ec2_ssh
   terraform apply
   ```

2. **Remove from Git history** (destructive):
   ```bash
   # WARNING: Rewrites history, breaks team members' clones
   git filter-branch --force --index-filter \
     "git rm --cached --ignore-unmatch ec2-ssh-key.pem" \
     --prune-empty --tag-name-filter cat -- --all

   git push origin --force --all
   git push origin --force --tags
   ```

3. **Notify your team:**
   - Old private key is compromised
   - They need to re-clone the repository
   - Update any systems using the old key

4. **Audit for unauthorized access:**
   - Check CloudTrail for unexpected EC2 console sessions
   - Review VPC Flow Logs for unexpected SSH connections
   - Check application logs for suspicious activity

---

## Why Store Keys in Terraform at All?

### Educational Trade-offs

This lab prioritizes **learning convenience** over **production security**:

| Aspect | This Lab | Production |
|--------|----------|------------|
| **Goal** | Learn RDS connectivity, Secrets Manager, CloudWatch | Secure production infrastructure |
| **Lifetime** | Hours/days (then destroyed) | Months/years |
| **Access** | Individual student | Team with different roles |
| **Key rotation** | Not needed (disposable) | Required regularly |
| **Compliance** | Not applicable | May require SOC2, HIPAA, etc. |

### The Learning Value

Despite the security trade-offs:
- ✅ Students learn Terraform without manual AWS console clicking
- ✅ Infrastructure is 100% reproducible
- ✅ No manual key pair management (common beginner mistake)
- ✅ Forces conversation about state security
- ✅ Demonstrates separation of secrets (DB creds in Secrets Manager, SSH key in state)

---

## Recommendations by Environment

### Lab/Learning ✅ (This Project)
- Use this approach
- Accept the risks
- Use non-production account
- Destroy infrastructure after learning
- Extract key only when debugging is needed

### Development 🟡
- Consider Systems Manager Session Manager instead
- If using SSH keys, pre-create key pairs outside Terraform
- Use separate AWS accounts (dev/staging/prod)
- Implement backend encryption

### Production 🔴
- **DO NOT** generate SSH keys in Terraform
- **USE** AWS Systems Manager Session Manager
- **OR USE** pre-created key pairs stored in AWS Secrets Manager
- **REQUIRE** MFA for administrative access
- **ENABLE** full CloudTrail logging
- **IMPLEMENT** automated compliance scanning

---

## Additional Resources

- [Terraform Sensitive Data Documentation](https://developer.hashicorp.com/terraform/language/state/sensitive-data)
- [AWS Systems Manager Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html)
- [AWS Secrets Manager Best Practices](https://docs.aws.amazon.com/secretsmanager/latest/userguide/best-practices.html)
- [Terraform S3 Backend Encryption](https://developer.hashicorp.com/terraform/language/settings/backends/s3)
- [OWASP Secrets Management Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html)

---

## Summary

**This lab uses a convenient but security-conscious approach to SSH key management:**

1. ✅ Keys are generated automatically (good for learning)
2. ⚠️ Keys are stored in Terraform state (requires secure backend)
3. 🔴 Extracting keys to disk is high-risk (rely on .gitignore + memory)

**For production: Use AWS Systems Manager Session Manager instead of SSH.**

**Remember:** The biggest security boundary in this design is not the encrypted S3 bucket or IAM policies—it's the moment you run `terraform output -raw ssh_private_key > ec2-ssh-key.pem` and trust yourself not to commit it.
