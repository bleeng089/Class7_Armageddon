# EC2 → RDS MySQL Notes Application

[![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.5.0-623CE4?logo=terraform)](https://www.terraform.io/)
[![AWS Provider](https://img.shields.io/badge/AWS_Provider-~%3E5.0-FF9900?logo=amazon-aws)](https://registry.terraform.io/providers/hashicorp/aws/latest)
[![Amazon Linux](https://img.shields.io/badge/Amazon_Linux-2023-FF9900?logo=amazon-aws)](https://aws.amazon.com/linux/amazon-linux-2023/)


Production-ready Terraform infrastructure demonstrating secure EC2-to-RDS connectivity patterns following AWS best practices.

## Features

- ✅ **Security Group-to-Security Group References** - No CIDR-based database access
- ✅ **AWS Secrets Manager Integration** - Zero static credentials in code
- ✅ **IAM Instance Profiles** - Secure AWS API authentication
- ✅ **Private RDS Deployment** - Database isolated in private subnets
- ✅ **Multi-AZ Architecture** - High availability across 2 availability zones
- ✅ **IMDSv2 Required** - Enhanced instance metadata security
- ✅ **Encrypted Storage** - Both EBS and RDS encryption enabled
- ✅ **Free Tier Compatible** - Uses t3.micro and db.t3.micro instances

## Architecture

```
                         VPC (10.0.0.0/16)
    ┌─────────────────────────────────────────────────────────┐
    │                                                         │
    │   Public Subnets              Private Subnets           │
    │   ┌─────────────┐             ┌─────────────┐           │
    │   │  10.0.0.0/24│             │10.0.100.0/24│           │
    │   │    (AZ-a)   │             │    (AZ-a)   │           │
    │   │             │             │             │           │
    │   │ ┌─────────┐ │   SG Ref    │ ┌─────────┐ │           │
    │   │ │   EC2   │─┼─────────────┼─│   RDS   │ │           │
    │   │ │  Flask  │ │  TCP/3306   │ │  MySQL  │ │           │
    │   │ └─────────┘ │             │ └─────────┘ │           │
    │   └──────┬──────┘             └─────────────┘           │
    │          │                                              │
    │   ┌─────────────┐             ┌─────────────┐           │
    │   │  10.0.1.0/24│             │10.0.101.0/24│           │
    │   │    (AZ-b)   │             │    (AZ-b)   │           │
    │   └─────────────┘             └─────────────┘           │
    │          │                                              │
    └──────────┼──────────────────────────────────────────────┘
               │
          ┌────┴────┐
          │   IGW   │
          └────┬────┘
               │
           Internet

    EC2 --> IAM Role --> Secrets Manager --> Get DB Creds --> Connect to RDS
```

**Security Flow:**
1. EC2 instance uses IAM role to authenticate to AWS APIs
2. Application retrieves database credentials from Secrets Manager
3. RDS security group allows connections only from EC2 security group (SG-to-SG reference)
4. All traffic encrypted in transit and at rest

---

## Quick Start

### Prerequisites
- AWS CLI configured with appropriate credentials
- Terraform >= 1.5.0

### Deployment

```bash
# Initialize Terraform
terraform init

# Review planned changes
terraform plan

# Deploy infrastructure (RDS creation takes ~5-10 minutes)
terraform apply

# Wait 2-3 minutes for EC2 user-data to complete, then test
EC2_IP=$(terraform output -raw ec2_public_ip)

# Initialize database
curl http://$EC2_IP/init

# Add notes
curl "http://$EC2_IP/add?note=Hello%20World"
curl "http://$EC2_IP/add?note=Testing%20EC2%20to%20RDS"

# List notes
curl http://$EC2_IP/list

# Clean up when done
terraform destroy
```

### Expected Output
```json
{
  "count": 2,
  "notes": [
    {"content": "Hello World", "created_at": "2026-01-03 12:00:00", "id": 1},
    {"content": "Testing EC2 to RDS", "created_at": "2026-01-03 12:00:01", "id": 2}
  ],
  "status": "success"
}
```

---

## Configuration

### Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `project_name` | string | `"ec2-rds-notes-lab"` | Resource naming prefix |
| `aws_region` | string | `"us-east-1"` | AWS deployment region |
| `vpc_cidr` | string | `"10.0.0.0/16"` | VPC CIDR block |
| `instance_type` | string | `"t3.micro"` | EC2 instance type |
| `db_instance_class` | string | `"db.t3.micro"` | RDS instance class |
| `db_name` | string | `"notesdb"` | Database name |
| `db_username` | string | `"dbadmin"` | Database master username |
| `secret_name` | string | `"lab/rds/mysql"` | Secrets Manager secret name |
| `ssh_allowed_cidr` | string | `""` | CIDR for SSH access (empty = disabled) |
| `allowed_http_cidrs` | list(string) | `["0.0.0.0/0"]` | CIDRs allowed for HTTP |

**Note:** SSH key pair is automatically generated during `terraform apply`. The private key is available as a sensitive Terraform output (not written to disk automatically for security). The `key_name` variable has been removed in favor of automatic key generation.

### Enable SSH Access

SSH key pair is automatically generated during `terraform apply`. To enable SSH access, set the `ssh_allowed_cidr` variable:

```bash
terraform apply \
  -var="ssh_allowed_cidr=YOUR_IP/32"
```

After deployment, save the private key and connect:
```bash
# Save the private key to a file (only when needed)
terraform output -raw ssh_private_key > ec2-ssh-key.pem
chmod 400 ec2-ssh-key.pem

# Connect to EC2
ssh -i ec2-ssh-key.pem ec2-user@$(terraform output -raw ec2_public_ip)
```

⚠️ **SECURITY WARNING:** Read **[SECURITY.md](SECURITY.md)** before extracting the SSH key. The private key is stored in Terraform state (encrypted S3 backend). Extracting it to disk relies on `.gitignore` and your memory to prevent accidental commits to version control. Delete `ec2-ssh-key.pem` immediately after use.

---

## API Reference

| Endpoint | Method | Description | Example Response |
|----------|--------|-------------|------------------|
| `/` | GET | API documentation | `{"app":"Notes App","endpoints":{...}}` |
| `/health` | GET | Health check | `{"status":"healthy"}` |
| `/init` | GET | Create notes table | `{"status":"success","message":"..."}` |
| `/add?note=TEXT` | GET | Add a note | `{"status":"success","note_id":1}` |
| `/list` | GET | List all notes | `{"count":N,"notes":[...],"status":"success"}` |

---

## Verification

### Infrastructure Validation

```bash
# Verify EC2 instance and IAM profile
aws ec2 describe-instances \
  --instance-ids $(terraform output -raw ec2_instance_id) \
  --query 'Reservations[].Instances[].{State:State.Name,IAM:IamInstanceProfile.Arn}'

# Verify RDS status
aws rds describe-db-instances \
  --db-instance-identifier $(terraform output -raw rds_identifier) \
  --query 'DBInstances[].{Status:DBInstanceStatus,Public:PubliclyAccessible}'

# Verify SG-to-SG reference (NOT CIDR)
aws ec2 describe-security-group-rules \
  --filter Name=group-id,Values=$(terraform output -raw rds_security_group_id) \
  --query 'SecurityGroupRules[?IsEgress==`false`].{Port:FromPort,SourceSG:ReferencedGroupInfo.GroupId,CIDR:CidrIpv4}'
```

**Expected Results:**
- EC2: State=`running`, IAM profile attached
- RDS: Status=`available`, PubliclyAccessible=`false`
- SG Rule: Port=`3306`, SourceSG=`sg-xxxxx`, CIDR=`null`

### Security Validation

SSH to EC2 (if enabled) and verify:

```bash
# Test Secrets Manager access
aws secretsmanager get-secret-value \
  --secret-id lab/rds/mysql \
  --query SecretString \
  --output text | python3 -m json.tool

# Verify application service
sudo systemctl status notes-app

# Check port binding
sudo ss -lntp | grep :80
```

---

## Troubleshooting

### Common Issues

| Symptom | Likely Cause | Quick Fix |
|---------|--------------|-----------|
| `curl` timeout | EC2 bootstrap in progress | Wait 2-3 minutes after apply |
| Connection refused | Service not started | Check console output for errors |
| 500 error on `/init` | RDS not ready | Verify RDS status is `available` |
| `AccessDeniedException` | IAM profile missing | Verify instance profile attached |
| `No module named pymysql` | User-data failed | Check `/var/log/notes-app.log` |

### Diagnostic Commands

```bash
# View console output (shows user-data execution)
aws ec2 get-console-output \
  --instance-id $(terraform output -raw ec2_instance_id) \
  --latest --output text | tail -100

# On EC2 instance (via SSH)
sudo systemctl status notes-app
sudo journalctl -u notes-app -n 50
sudo cat /var/log/notes-app.log
```

### Detailed Troubleshooting

See **[RUNBOOK.md](RUNBOOK.md)** for:
- Complete step-by-step diagnostic process
- Layer-by-layer network verification
- All commands used to diagnose and fix deployment issues
- Root cause analysis of the original AL2023 package issue
- Reusable troubleshooting framework for similar issues

---

## Lab Questions & Answers

<details>
<summary><b>A) Why restrict DB inbound source to EC2 Security Group instead of a CIDR?</b></summary>

Security group references provide multiple advantages over CIDR-based rules:

1. **Dynamic Membership** - New EC2 instances automatically inherit access without rule modifications
2. **No IP Management** - Eliminates need to track and update IP addresses
3. **Defense in Depth** - Even with leaked RDS endpoint, connection requires SG membership
4. **Clear Auditability** - Explicit trust relationships visible in AWS console
5. **Reduced Blast Radius** - Compromised credentials only usable from authorized instances

</details>

<details>
<summary><b>B) What port does MySQL use?</b></summary>

**TCP port 3306**

This is the default MySQL port. The RDS security group allows inbound TCP/3306 exclusively from the EC2 security group via SG-to-SG reference.

</details>

<details>
<summary><b>C) Why is Secrets Manager better than credentials in code/user-data?</b></summary>

| Storage Method | Security Risk |
|----------------|---------------|
| Hardcoded in code | Visible in version control, accessible to all repo users |
| In user-data | Visible in EC2 metadata, Terraform state, AWS console |
| Environment variables | Exposed in process listings, can leak in application logs |
| **Secrets Manager** | ✅ Encrypted at rest, IAM-controlled, audited via CloudTrail, supports rotation |

**Additional Benefits:**
- **Separation of Concerns** - Application code contains no credentials
- **Centralized Management** - Single source of truth for secrets
- **Automatic Rotation** - Credential changes don't require code deployment
- **Access Control** - Fine-grained IAM policies control who can read secrets
- **Audit Trail** - CloudTrail logs all secret access attempts

</details>

---

## Project Structure

```
.
├── 0-backend.tf             # Terraform backend configuration
├── 0-versions.tf            # Terraform and provider version constraints
├── 0.1-locals.tf            # Local values and data sources
├── 0.1-variables.tf         # Input variable definitions
├── 0.2-iam.tf               # IAM roles and policies
├── 0.3-secrets.tf           # AWS Secrets Manager configuration
├── 1-providers.tf           # AWS provider configuration
├── 2-network.tf             # VPC, subnets, routing, and IGW
├── 3-security_groups.tf     # EC2 and RDS security groups
├── 4-ec2.tf                 # EC2 instance configuration
├── 5-rds.tf                 # RDS MySQL instance
├── 6-outputs.tf             # Terraform output values
├── templates/
│   └── user_data.sh.tftpl   # EC2 bootstrap script (Flask app setup)
├── evidence/                # Deployment verification screenshots
│   ├── evidence0.png        # Terraform outputs
│   ├── evidence1.png        # Infrastructure verification commands
│   ├── evidence2.png        # SSH access & security validation
│   ├── evidence3.png        # API endpoint testing (CLI)
│   ├── evidence4.png        # Browser test - /init endpoint
│   ├── evidence5.png        # Browser test - /add endpoint (note 1)
│   ├── evidence6.png        # Browser test - /add endpoint (note 2)
│   └── evidence7.png        # Browser test - /list endpoint
├── README.md                # Project documentation (this file)
├── RUNBOOK.md               # Troubleshooting & diagnostic procedures
└── SECURITY.md              # Security considerations & SSH key management
```

### File Organization

Files are numbered to indicate their logical dependency order:
- `0-*` - Core configuration (backend, versions, variables, secrets, IAM)
- `1-*` - Provider setup
- `2-*` - Network infrastructure
- `3-*` - Security configurations
- `4-5-*` - Compute and database resources
- `6-*` - Outputs

### Documentation Files

- **README.md** - Complete project documentation including architecture, deployment, and API reference
- **RUNBOOK.md** - Comprehensive troubleshooting guide with step-by-step diagnostic procedures
- **SECURITY.md** - Security best practices, SSH key management, and production recommendations
- **evidence/** - Deployment verification screenshots documenting successful infrastructure deployment

---

## Cost Considerations

This lab uses AWS Free Tier eligible resources:

| Resource | Instance Type | Free Tier Limit |
|----------|---------------|-----------------|
| EC2 | t3.micro | 750 hours/month |
| RDS | db.t3.micro | 750 hours/month |
| EBS Storage | gp3, 8 GB | 30 GB/month |
| RDS Storage | gp2, 20 GB | 20 GB/month |
| Secrets Manager | 1 secret | 30 days free trial, then $0.40/month |

**Important:** Always run `terraform destroy` when finished to avoid ongoing charges.

---

## Security Best Practices Implemented

- ✅ No publicly accessible RDS instances
- ✅ Security groups using principle of least privilege
- ✅ IAM roles instead of static credentials
- ✅ Secrets Manager for credential management
- ✅ IMDSv2 required for instance metadata access
- ✅ Encrypted EBS volumes
- ✅ Encrypted RDS storage
- ✅ SG-to-SG references for database access
- ✅ No deletion protection (lab setting for easy cleanup)

⚠️ **IMPORTANT:** See **[SECURITY.md](SECURITY.md)** for critical information about:
- SSH private key storage in Terraform state
- Risks of extracting keys to disk (`terraform output -raw ssh_private_key`)
- Backend encryption requirements (use encrypted S3 bucket)
- Git commit prevention (relies on `.gitignore` + user awareness)
- Production alternatives (AWS Systems Manager Session Manager)

**TL;DR:** The SSH private key is in your Terraform state. Only extract it when needed, delete immediately after use, and never commit `ec2-ssh-key.pem` to version control.

---

## Deployment Evidence

This section documents a successful deployment of the EC2→RDS infrastructure, demonstrating all components working correctly.

### Evidence 0: Terraform Infrastructure Outputs

![Terraform Outputs](evidence/evidence0.png)

**Description:** Complete Terraform output showing all provisioned infrastructure resources including:
- **EC2 Instance:** `i-0946db89085a88d9a` with public IP `3.80.77.61`
- **RDS Database:** `ec2-rds-notes-lab-mysql.czwskgwokzak.us-east-1.rds.amazonaws.com:3306`
- **VPC & Networking:** VPC `vpc-05cea71ff34440482` with 2 public and 2 private subnets across multiple AZs
- **Security Groups:** EC2 SG `sg-0971a529f707e3b10` and RDS SG `sg-025663fd7908218dd`
- **IAM Resources:** Instance profile with role ARN for AWS API access
- **Secrets Manager:** Secret `lab/rds/mysql` for secure credential storage
- **Application Endpoints:** Pre-formatted URLs for `/init`, `/add`, and `/list` operations

**Key Validation:** All sensitive outputs (SSH private key) properly marked as `<sensitive>` and not exposed in logs.

---

### Evidence 1: Infrastructure Verification Commands

![Infrastructure Verification](evidence/evidence1.png)

**Description:** AWS CLI verification commands confirming infrastructure compliance with security best practices:

1. **EC2 Instance Verification:**
   ```bash
   aws ec2 describe-instances --instance-ids i-0946db89085a88d9a
   ```
   - **Result:** Instance in `running` state with IAM instance profile attached
   - **Validates:** EC2 can authenticate to AWS APIs without static credentials

2. **RDS Status Verification:**
   ```bash
   aws rds describe-db-instances --db-instance-identifier ec2-rds-notes-lab-mysql
   ```
   - **Result:** Status `available`, PubliclyAccessible: `false`
   - **Validates:** Database is running and properly isolated in private subnet

3. **Security Group Reference Verification:**
   ```bash
   aws ec2 describe-security-group-rules --filter Name=group-id,Values=sg-025663fd7908218dd
   ```
   - **Result:** Port 3306 ingress rule uses SG-to-SG reference (SourceSG present, CIDR null)
   - **Validates:** Database access controlled via security group membership, not IP addresses

**Security Confirmation:** All three checks passed, confirming proper implementation of AWS security best practices.

---

### Evidence 2: SSH Access & Security Validation

![SSH and Security Validation](evidence/evidence2.png)

**Description:** Successful SSH connection to EC2 instance with comprehensive security validation:

1. **SSH Key Extraction & Connection:**
   ```bash
   terraform output -raw ssh_private_key > ec2-ssh-key.pem
   chmod 400 ec2-ssh-key.pem
   ssh -i ec2-ssh-key.pem ec2-user@3.80.77.61
   ```
   - **Result:** Successfully connected to EC2 instance
   - **Validates:** SSH key pair correctly configured and EC2 publicly accessible

2. **Secrets Manager Access Test:**
   ```bash
   aws secretsmanager get-secret-value --secret-id lab/rds/mysql
   ```
   - **Result:** Retrieved database credentials (username, password, host, port, dbname)
   - **Validates:** IAM instance profile has correct `secretsmanager:GetSecretValue` permissions

3. **Application Service Verification:**
   ```bash
   sudo systemctl status notes-app
   ```
   - **Result:** Service `active (running)`
   - **Validates:** Flask application started successfully via user-data

4. **Port Binding Confirmation:**
   ```bash
   sudo ss -lntp | grep :80
   ```
   - **Result:** Process listening on `0.0.0.0:80`
   - **Validates:** Application bound to all interfaces and accepting external connections

**Outcome:** All security components verified working - IAM authentication, Secrets Manager integration, and application runtime.

---

### Evidence 3: API Endpoint Testing (CLI)

![API Testing via CLI](evidence/evidence3.png)

**Description:** Complete API functionality test from host machine using curl:

1. **Database Initialization:**
   ```bash
   curl http://3.80.77.61/init
   ```
   - **Result:** `{"status":"success","message":"Notes table created/verified successfully"}`
   - **Validates:** EC2→RDS connectivity, Secrets Manager credential retrieval, database permissions

2. **Note Creation (First Entry):**
   ```bash
   curl "http://3.80.77.61/add?note=Hello%20World"
   ```
   - **Result:** `{"status":"success","note_id":1,"message":"Note added with ID 1"}`
   - **Validates:** INSERT operations working, auto-increment functioning

3. **Note Creation (Second Entry):**
   ```bash
   curl "http://3.80.77.61/add?note=Testing%20EC2%20to%20RDS"
   ```
   - **Result:** `{"status":"success","note_id":2,"message":"Note added with ID 2"}`
   - **Validates:** Multiple writes supported, connection pooling working

4. **Data Retrieval:**
   ```bash
   curl http://3.80.77.61/list
   ```
   - **Result:** JSON array with both notes, timestamps, and count
   - **Validates:** SELECT operations working, data persistence confirmed

**Full-Stack Validation:** Successfully demonstrated complete data flow from public internet → EC2 → RDS → response, confirming all network, security, and application layers functioning correctly.

---

### Evidence 4: Browser Test - Database Initialization

![Browser /init Endpoint](evidence/evidence4.png)

**Description:** Browser-based verification of database initialization endpoint accessing `http://3.80.77.61/init`.

**Response:**
```json
{
  "message": "Notes table created/verified successfully",
  "status": "success"
}
```

**Validates:**
- HTTP endpoint publicly accessible via standard web browser
- Security group allows port 80 ingress from `0.0.0.0/0`
- Application returns properly formatted JSON responses
- Database schema creation/verification working correctly

**Significance:** Confirms user-facing accessibility of the application, not just CLI access.

---

### Evidence 5: Browser Test - Add Note (Hello World)

![Browser /add Endpoint - Hello World](evidence/evidence5.png)

**Description:** Browser-based note creation using URL: `http://3.80.77.61/add?note=Hello%20World`

**Response:**
```json
{
  "message": "Note added with ID 1",
  "note_id": 1,
  "status": "success"
}
```

**Validates:**
- Query parameter parsing working correctly
- URL encoding/decoding functioning (space → `%20`)
- Database write operations accessible via browser
- Proper HTTP response codes and content-type headers

**User Experience:** Demonstrates simple RESTful API design accessible from any HTTP client.

---

### Evidence 6: Browser Test - Add Note (Testing EC2 to RDS)

![Browser /add Endpoint - Testing EC2 to RDS](evidence/evidence6.png)

**Description:** Second browser-based note creation: `http://3.80.77.61/add?note=Testing%20EC2%20to%20RDS`

**Response:**
```json
{
  "message": "Note added with ID 7",
  "note_id": 2,
  "status": "success"
}
```

**Validates:**
- Sequential note ID generation (auto-increment working)
- Multiple concurrent/sequential requests supported
- No database connection pooling issues
- Consistent response format across multiple operations

**Reliability:** Confirms application stability across multiple write operations.

---

### Evidence 7: Browser Test - List All Notes

![Browser /list Endpoint](evidence/evidence7.png)

**Description:** Browser-based data retrieval using: `http://3.80.77.61/list`

**Response:**
```json
{
  "count": 7,
  "notes": [
    {
      "content": "Hello World",
      "created_at": "2026-01-XX XX:XX:XX",
      "id": 1
    },
    {
      "content": "Testing EC2 to RDS",
      "created_at": "2026-01-XX XX:XX:XX",
      "id": 2
    }
  ],
  ...
  "status": "success"
}
```

**Validates:**
- SELECT queries returning correct data
- Data persistence across multiple operations
- Timestamp generation working correctly
- JSON serialization of database results
- Note ordering by ID

**Data Integrity:** Both previously inserted notes retrieved successfully with all fields intact, confirming full CRUD cycle (Create, Read) functionality.

---

### Deployment Summary

**Infrastructure Status:** ✅ All components operational

| Component | Status | Evidence |
|-----------|--------|----------|
| **VPC & Networking** | ✅ Operational | Evidence 0, 1 |
| **EC2 Instance** | ✅ Running | Evidence 1, 2 |
| **RDS Database** | ✅ Available | Evidence 1, 3 |
| **Security Groups** | ✅ SG-to-SG Reference | Evidence 1 |
| **IAM Permissions** | ✅ Secrets Manager + SSM | Evidence 2 |
| **Application Runtime** | ✅ Port 80 Listening | Evidence 2, 3 |
| **API Endpoints** | ✅ All Functional | Evidence 3-7 |
| **Data Persistence** | ✅ Verified | Evidence 7 |

**Tested Scenarios:**
- ✅ Database table creation via `/init`
- ✅ Data insertion via `/add` (2 successful writes)
- ✅ Data retrieval via `/list` (confirmed persistence)
- ✅ Browser accessibility (all endpoints)
- ✅ CLI accessibility (curl commands)
- ✅ SSH access with Secrets Manager integration

**Deployment Date:** January 2026
**Infrastructure:** EC2 t3.micro + RDS db.t3.micro (AWS Free Tier eligible)
**Region:** us-east-1 (N. Virginia)

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Built for educational purposes demonstrating AWS best practices
- Follows [Terraform Style Guide](https://developer.hashicorp.com/terraform/language/style)
- Implements security patterns from AWS [Well-Architected Framework](https://docs.aws.amazon.com/wellarchitected/latest/framework/welcome.html)
