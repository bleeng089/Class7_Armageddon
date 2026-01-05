# EC2 → RDS Labs: Infrastructure to Operations

[![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.5.0-623CE4?logo=terraform)](https://www.terraform.io/)
[![AWS Provider](https://img.shields.io/badge/AWS_Provider-~%3E5.0-FF9900?logo=amazon-aws)](https://registry.terraform.io/providers/hashicorp/aws/latest)
[![Amazon Linux](https://img.shields.io/badge/Amazon_Linux-2023-FF9900?logo=amazon-aws)](https://aws.amazon.com/linux/amazon-linux-2023/)

A progressive two-lab series demonstrating the evolution from secure infrastructure deployment to production-ready operations and incident response for an EC2-to-RDS application architecture.

---

## Lab Overview

| Lab | Focus | Complexity | Time |
|-----|-------|------------|------|
| **[Lab 1a](1a/)** | Infrastructure & Security | Foundation | 30-45 min |
| **[Lab 1b](1b/)** | Operations & Incident Response | Advanced | 60-90 min |

---

## Lab 1a: Secure Infrastructure Foundation

**📂 Directory:** [`1a/`](1a/)

**Objective:** Deploy secure EC2-to-RDS architecture following AWS best practices.

### What You'll Build

- VPC with public/private subnets across 2 AZs
- EC2 instance running Flask application
- RDS MySQL database in private subnets
- Security group-to-security group references
- AWS Secrets Manager for credential management
- IAM instance profiles for secure AWS API access

### Key Features

✅ **Zero Static Credentials** - Secrets Manager + IAM roles
✅ **Network Isolation** - RDS in private subnets only
✅ **SG-to-SG References** - No CIDR-based database access
✅ **Encrypted Storage** - EBS and RDS encryption enabled
✅ **IMDSv2 Required** - Enhanced metadata security
✅ **Comprehensive Documentation** - Includes troubleshooting runbook

### Quick Start

```bash
cd 1a
terraform init
terraform apply

# Test the application
EC2_IP=$(terraform output -raw ec2_public_ip)
curl http://$EC2_IP/init
curl "http://$EC2_IP/add?note=Hello%20World"
curl http://$EC2_IP/list
```

### Learning Outcomes

- Secure VPC design with public/private subnet separation
- Security group architecture and SG-to-SG references
- AWS Secrets Manager integration patterns
- IAM roles and instance profiles
- EC2 user-data and application bootstrapping
- RDS deployment in private subnets

**📖 Full Documentation:** [1a/README.md](1a/README.md)

---

## Lab 1b: Production Operations & Incident Response

**📂 Directory:** [`1b/`](1b/)

**Objective:** Extend Lab 1a with observability, monitoring, alerting, and incident response capabilities.

### What's Added to Lab 1a

- **Dual Secret Storage** - Parameter Store for operational metadata
- **Centralized Logging** - CloudWatch Logs with real-time log shipping
- **Proactive Monitoring** - Metric filters detecting DB connection failures
- **Automated Alerting** - CloudWatch Alarms with SNS notifications
- **Incident Response** - Comprehensive runbook with recovery procedures
- **Chaos Engineering** - Controlled failure tests to validate monitoring

### Architecture Evolution

```diff
Lab 1a:
  EC2 → Secrets Manager → RDS

Lab 1b:
  EC2 → {Secrets Manager, Parameter Store, CloudWatch}
         │
         ├─ Get DB Credentials (Secrets Manager)
         ├─ Get DB Metadata (Parameter Store)
         ├─ Ship Application Logs (CloudWatch Logs)
         └─ Metric Filter → Alarm → SNS Email
```

### Monitoring Pipeline

1. Application logs `DB_CONNECTION_FAILURE` errors to `/var/log/notes-app.log`
2. CloudWatch Agent ships logs to CloudWatch Logs group
3. Metric Filter matches error pattern, increments custom metric
4. Alarm triggers when errors >= 3 in 5-minute window
5. SNS topic sends email notification to on-call engineer

### Quick Start

```bash
cd 1b
terraform init
terraform apply -var="alert_email=your@email.com"

# Verify CloudWatch integration
aws logs describe-log-streams \
  --log-group-name /aws/ec2/lab-rds-app \
  --order-by LastEventTime \
  --descending

# Test alarm by simulating failure
aws rds stop-db-instance --db-instance-identifier ec2-rds-notes-lab-mysql
# Wait for alarm to trigger, then restore
aws rds start-db-instance --db-instance-identifier ec2-rds-notes-lab-mysql
```

### Learning Outcomes

- Dual secret management (Secrets Manager vs Parameter Store)
- CloudWatch Logs agent setup and configuration
- Log-based metric creation with metric filters
- CloudWatch Alarms with appropriate thresholds
- SNS topic integration for incident notifications
- Incident response procedures and runbooks
- Chaos engineering for resilience testing

### Incident Response Features

**3 Documented Failure Modes:**
1. **Credential Drift** - Password mismatch between Secrets Manager and RDS
2. **Network Isolation** - Missing security group rules
3. **Database Unavailability** - RDS instance stopped or crashed

**Each includes:**
- Step-by-step detection procedures
- Root cause analysis commands
- Recovery workflows
- Validation steps

**Chaos Engineering Tests:**
- Controlled failure injection scripts
- Automated test suite covering all 3 failure modes
- Practice scenarios for team training

**📖 Full Documentation:** [1b/README.md](1b/README.md)
**📘 Incident Runbook:** [1b/RUNBOOK.md](1b/RUNBOOK.md)

---

## Lab Progression

### Recommended Learning Path

1. **Start with Lab 1a** - Build foundation understanding
   - Deploy secure infrastructure
   - Understand VPC networking patterns
   - Practice Secrets Manager integration
   - Verify application functionality

2. **Progress to Lab 1b** - Add operational capabilities
   - Enable centralized logging
   - Configure monitoring and alerting
   - Practice incident response procedures
   - Run chaos engineering tests

### Skills Developed

| Category | Lab 1a | Lab 1b |
|----------|--------|--------|
| **Infrastructure** | VPC, EC2, RDS, Security Groups | + Parameter Store, CloudWatch |
| **Security** | Secrets Manager, IAM, Encryption | + Enhanced IAM policies |
| **Networking** | Public/private subnets, IGW, SG-to-SG | Same |
| **Monitoring** | None | Logs, Metrics, Alarms, SNS |
| **Operations** | Manual SSH troubleshooting | Automated detection + Runbook |
| **Testing** | Manual verification | Chaos engineering |

---

## Key Differences: 1a vs 1b

| Feature | Lab 1a | Lab 1b |
|---------|--------|--------|
| **Secret Storage** | Secrets Manager only | Secrets Manager + Parameter Store |
| **Logging** | Local file only (`/var/log/notes-app.log`) | Local + CloudWatch Logs |
| **Monitoring** | None | Metric Filter + CloudWatch Alarm |
| **Alerting** | None | SNS email notifications |
| **IAM Permissions** | Secrets Manager read | + SSM, CloudWatch Logs, Metrics |
| **User-Data** | Basic Flask setup | + CloudWatch Agent installation |
| **Error Handling** | Generic logs | Structured logging with error tokens |
| **Incident Response** | Manual SSH diagnosis | Automated detection + CLI runbook |
| **Documentation** | README + RUNBOOK | README + RUNBOOK + Chaos Tests |
| **Terraform Resources** | 18 resources | 24 resources |

---

## Architecture Comparison

### Lab 1a: Secure Infrastructure
```
┌─────────────────────────────────────────┐
│              VPC (10.0.0.0/16)          │
│                                         │
│  Public Subnet        Private Subnet    │
│  ┌──────────┐        ┌──────────┐       │
│  │   EC2    │─SG Ref─│   RDS    │       │
│  │  Flask   │        │  MySQL   │       │
│  └────┬─────┘        └──────────┘       │
│       │                                 │
└───────┼─────────────────────────────────┘
        │
     Internet
        ▲
        │
   IAM + Secrets Manager
```

### Lab 1b: Operations & Monitoring
```
┌─────────────────────────────────────────────────────┐
│              VPC (10.0.0.0/16)                      │
│                                                     │
│  Public Subnet        Private Subnet                │
│  ┌──────────┐        ┌──────────┐                   │
│  │   EC2    │─SG Ref─│   RDS    │                   │
│  │  Flask   │        │  MySQL   │                   │
│  │ + CW Agt │        └──────────┘                   │
│  └────┬─────┘                                       │
│       │                                             │
└───────┼─────────────────────────────────────────────┘
        │
     Internet
        ▲
        │
   IAM + Secrets + Params + CloudWatch
                              │
                              ├─ Logs
                              ├─ Metrics
                              └─ Alarms → SNS → Email
```

---

## Prerequisites

- AWS Account with appropriate permissions
- AWS CLI configured (`aws configure`)
- Terraform >= 1.5.0 installed
- `jq` for JSON parsing (Lab 1b)
- Basic understanding of:
  - VPC networking concepts
  - Security groups
  - IAM roles and policies
  - RDS MySQL

---

## Cost Considerations

Both labs use **AWS Free Tier eligible** resources:

| Resource | Type | Free Tier Limit | After Free Tier |
|----------|------|-----------------|-----------------|
| EC2 | t3.micro | 750 hours/month | ~$7.50/month |
| RDS | db.t3.micro | 750 hours/month | ~$12/month |
| EBS | gp3 8GB | 30 GB/month | $0.80/month |
| RDS Storage | gp2 20GB | 20 GB/month | $2.30/month |
| Secrets Manager | 1 secret | 30-day trial | $0.40/month |
| CloudWatch Logs (1b) | Log ingestion | 5GB/month | $0.50/GB after |
| CloudWatch Metrics (1b) | Custom metrics | 10 metrics | $0.30/metric/month after |

**Estimated cost per lab** (if running continuously outside free tier):
- **Lab 1a:** ~$20-25/month
- **Lab 1b:** ~$22-28/month (additional CloudWatch costs)

**💡 Cost Optimization:**
- Destroy resources when not in use: `terraform destroy`
- Both labs deploy in `us-east-1` (lowest AWS pricing region)
- Use `terraform destroy -auto-approve` for quick cleanup

---

## Repository Structure

```
.
├── 1a/                          # Lab 1a: Secure Infrastructure
│   ├── 0-backend.tf             # S3 backend configuration
│   ├── 0-versions.tf            # Terraform/provider versions
│   ├── 0.1-locals.tf            # Local values
│   ├── 0.1-variables.tf         # Input variables
│   ├── 0.2-iam.tf               # IAM roles and policies
│   ├── 0.3-secrets.tf           # Secrets Manager
│   ├── 1-providers.tf           # AWS provider
│   ├── 2-network.tf             # VPC, subnets, IGW, routes
│   ├── 3-security_groups.tf     # EC2 and RDS security groups
│   ├── 4-ec2.tf                 # EC2 instance
│   ├── 5-rds.tf                 # RDS MySQL instance
│   ├── 6-outputs.tf             # Terraform outputs
│   ├── templates/
│   │   └── user_data.sh.tftpl   # EC2 bootstrap script
│   ├── evidence/                # Deployment screenshots
│   ├── README.md                # Lab 1a documentation
│   ├── RUNBOOK.md               # Troubleshooting guide
│   └── SECURITY.md              # Security considerations
│
├── 1b/                          # Lab 1b: Operations & Monitoring
│   ├── 0-backend.tf             # S3 backend configuration
│   ├── 0-versions.tf            # Terraform/provider versions
│   ├── 0.1-locals.tf            # Local values
│   ├── 0.1-variables.tf         # Input variables (+ monitoring vars)
│   ├── 0.2-iam.tf               # IAM roles (+ CloudWatch permissions)
│   ├── 0.3-secrets.tf           # Secrets Manager + Parameter Store
│   ├── 1-providers.tf           # AWS provider
│   ├── 2-network.tf             # VPC, subnets, IGW, routes
│   ├── 3-security_groups.tf     # EC2 and RDS security groups
│   ├── 4-ec2.tf                 # EC2 instance
│   ├── 5-rds.tf                 # RDS MySQL instance
│   ├── 6-cloudwatch.tf          # Logs, Metric Filters, Alarms, SNS (NEW)
│   ├── 7-outputs.tf             # Terraform outputs (+ monitoring outputs)
│   ├── templates/
│   │   └── user_data.sh.tftpl   # EC2 bootstrap + CloudWatch Agent
│   ├── README.md                # Lab 1b documentation
│   ├── RUNBOOK.md               # Incident response + Chaos engineering
│   └── SECURITY.md              # Security considerations
│
└── README.md                    # This file
```

---

## Getting Started

### Option 1: Sequential Learning (Recommended)

```bash
# Start with Lab 1a
cd 1a
terraform init
terraform apply
# Explore, test, understand
terraform destroy

# Progress to Lab 1b
cd ../1b
terraform init
terraform apply -var="alert_email=your@email.com"
# Run verification steps, trigger alarms, practice runbook
terraform destroy
```

### Option 2: Direct to Lab 1b

If you're already familiar with VPC/EC2/RDS basics:

```bash
cd 1b
terraform init
terraform apply -var="alert_email=your@email.com"
```

**Note:** Lab 1b is standalone - you don't need to deploy Lab 1a first.

---

## Documentation Links

### Lab 1a Resources
- **[README.md](1a/README.md)** - Complete lab documentation
- **[RUNBOOK.md](1a/RUNBOOK.md)** - Troubleshooting procedures
- **[SECURITY.md](1a/SECURITY.md)** - SSH key management and security

### Lab 1b Resources
- **[README.md](1b/README.md)** - Complete lab documentation
- **[RUNBOOK.md](1b/RUNBOOK.md)** - Incident response + chaos engineering
- **[SECURITY.md](1b/SECURITY.md)** - SSH key management and security

---

## Common Issues & Solutions

### Issue: Terraform State Lock

**Error:** `Error locking state: resource temporarily unavailable`

**Solution:**
```bash
# If backend uses S3, check for stale locks
aws dynamodb describe-table --table-name terraform-state-lock

# Force unlock (use carefully)
terraform force-unlock <LOCK_ID>
```

### Issue: RDS Creation Timeout

**Symptom:** RDS takes > 10 minutes to create

**Explanation:** This is normal. RDS provisioning includes:
- Compute instance launch (~3 min)
- Storage allocation (~2 min)
- Backup configuration (~2 min)
- Multi-AZ standby setup (~3 min if enabled)

**Total:** 5-12 minutes is expected

### Issue: Application Not Responding

**Lab 1a:** See [1a/RUNBOOK.md](1a/RUNBOOK.md) for layer-by-layer diagnosis
**Lab 1b:** See [1b/RUNBOOK.md](1b/RUNBOOK.md) for incident response procedures

---

## Learning Resources

- [AWS Well-Architected Framework](https://docs.aws.amazon.com/wellarchitected/latest/framework/welcome.html)
- [Terraform AWS Provider Documentation](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [AWS VPC Documentation](https://docs.aws.amazon.com/vpc/latest/userguide/what-is-amazon-vpc.html)
- [Amazon RDS Best Practices](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_BestPractices.html)
- [CloudWatch Agent Configuration](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-Agent-Configuration-File-Details.html)

---

## License

This project is licensed under the MIT License - see the [LICENSE](1a/LICENSE) file for details.

## Acknowledgments

- Built for educational purposes demonstrating AWS best practices
- Follows [Terraform Style Guide](https://developer.hashicorp.com/terraform/language/style)
- Implements patterns from AWS Well-Architected Framework
- CloudWatch integration based on AWS official documentation
