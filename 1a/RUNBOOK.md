# EC2→RDS Lab Troubleshooting Guide

## Overview
This document provides a comprehensive, step-by-step troubleshooting framework for diagnosing "port 80 unreachable" issues in an EC2→RDS Terraform deployment. Each command includes full context, rationale, and interpretation.

---

## Original Issue
After `terraform apply`, the Flask application on EC2 was unreachable at `http://3.95.61.19/init` with:
```
curl: (28) Failed to connect to 3.95.61.19 port 80 ... Connection timed out
```

**Initial Facts from Terraform Output:**
- EC2 Instance ID: `i-05e2273d23d9c69ca`
- EC2 Public IP: `3.95.61.19`
- EC2 Security Group: `sg-00a9308f90477ac01`
- RDS Security Group: `sg-03dfdbb04dc26007a`
- VPC: `vpc-0249929ee2ba91a30`
- Public Subnets: `subnet-08391b9e0a40554ac`, `subnet-01644f900d14a2306`
- Private Subnets: `subnet-0e46ea12edc253a39`, `subnet-0282557a0cae63f70`

---

## Sequential Troubleshooting Process

### Understanding the Error Code
**Context**: `curl: (28) Connection timed out` means:
- The TCP connection attempt didn't complete within the timeout period
- Packets are being dropped (firewall/security group) OR nothing is listening on the port
- This is different from "Connection refused" (port actively rejecting connections)

**Possible causes** (in order of likelihood):
1. Application not running (user-data failed, service crashed)
2. Security group blocking port 80
3. No route to internet gateway
4. Instance not in public subnet or no public IP
5. NACL blocking traffic
6. Application bound to localhost (127.0.0.1) instead of 0.0.0.0

---

## Layer 1: Verify EC2 Instance Network Configuration

### Step 1.1: Check Instance Status, Public IP, and Security Group Attachment

**Why**: Confirm the instance is running, has a public IP, is in the correct subnet, and has the expected security group attached.

```bash
aws ec2 describe-instances \
  --instance-ids i-05e2273d23d9c69ca \
  --query 'Reservations[0].Instances[0].{
    State:State.Name,
    PublicIP:PublicIpAddress,
    PrivateIP:PrivateIpAddress,
    SubnetId:SubnetId,
    VpcId:VpcId,
    SecurityGroups:SecurityGroups[*].[GroupId,GroupName],
    PublicDnsName:PublicDnsName
  }' \
  --output json
```

**Expected Output**:
```json
{
  "State": "running",
  "PublicIP": "3.95.61.19",
  "PrivateIP": "10.0.0.190",
  "SubnetId": "subnet-08391b9e0a40554ac",
  "VpcId": "vpc-0249929ee2ba91a30",
  "SecurityGroups": [
    [
      "sg-00a9308f90477ac01",
      "ec2-rds-notes-lab-ec2-sg"
    ]
  ],
  "PublicDnsName": "ec2-3-95-61-19.compute-1.amazonaws.com"
}
```

**Interpretation**:
- ✅ State = "running" (instance is up)
- ✅ PublicIP exists (instance has public IP)
- ✅ SubnetId matches one of the public subnets
- ✅ SecurityGroups contains the expected SG ID
- ❌ If PublicIP is null → instance in wrong subnet or auto-assign disabled
- ❌ If SecurityGroups is wrong → incorrect SG attached

**Result**: ✅ All checks passed - instance networking is configured correctly

---

## Layer 2: Verify Route Table and Internet Gateway

### Step 2.1: Check Route Table Associated with Subnet

**Why**: Confirm the public subnet has a route table with 0.0.0.0/0 → IGW. Without this route, the instance can't receive traffic from the internet.

```bash
aws ec2 describe-route-tables \
  --filters "Name=association.subnet-id,Values=subnet-08391b9e0a40554ac" \
  --query 'RouteTables[*].{
    RouteTableId:RouteTableId,
    Routes:Routes[*].[DestinationCidrBlock,GatewayId,State]
  }' \
  --output json
```

**Expected Output**:
```json
[
  {
    "RouteTableId": "rtb-0b7a1468b88c1e7c7",
    "Routes": [
      [
        "10.0.0.0/16",
        "local",
        "active"
      ],
      [
        "0.0.0.0/0",
        "igw-00a1c2c3048ca9555",
        "active"
      ]
    ]
  }
]
```

**Interpretation**:
- ✅ Route exists: `0.0.0.0/0` → `igw-xxxxxxxx` with State=`active`
- ✅ Local VPC route: `10.0.0.0/16` → `local`
- ❌ If no IGW route → subnet is not actually public
- ❌ If using main route table without IGW → common misconfiguration

**Result**: ✅ Route table correctly configured with IGW route

---

## Layer 3: Verify Security Group Rules

### Step 3.1: Check EC2 Security Group Ingress Rules

**Why**: Verify that port 80 (HTTP) is allowed from 0.0.0.0/0 (or your IP).

```bash
aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=sg-00a9308f90477ac01" \
  --query 'SecurityGroupRules[?IsEgress==`false`].{
    FromPort:FromPort,
    ToPort:ToPort,
    IpProtocol:IpProtocol,
    CidrIpv4:CidrIpv4,
    Description:Description
  }' \
  --output table
```

**Expected Output**:
```
--------------------------------------------------------------------------
|                       DescribeSecurityGroupRules                       |
+-----------+-----------------------+-----------+-------------+----------+
| CidrIpv4  |      Description      | FromPort  | IpProtocol  | ToPort   |
+-----------+-----------------------+-----------+-------------+----------+
|  0.0.0.0/0|  HTTP from 0.0.0.0/0  |  80       |  tcp        |  80      |
+-----------+-----------------------+-----------+-------------+----------+
```

**Interpretation**:
- ✅ Port 80 TCP is allowed from 0.0.0.0/0
- ❌ If no rule for port 80 → security group not configured correctly
- ❌ If CIDR is restrictive and doesn't include your IP → you're blocked

**Result**: ✅ Port 80 ingress rule exists

### Step 3.2: Check EC2 Security Group Egress Rules

**Why**: Verify the instance can make outbound connections (needed for package installation, AWS API calls, and RDS connections).

```bash
aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=sg-00a9308f90477ac01" \
  --query 'SecurityGroupRules[?IsEgress==`true`].{
    IpProtocol:IpProtocol,
    CidrIpv4:CidrIpv4,
    Description:Description
  }' \
  --output table
```

**Expected Output**:
```
-----------------------------------------------------
|            DescribeSecurityGroupRules             |
+-----------+------------------------+--------------+
| CidrIpv4  |      Description       | IpProtocol   |
+-----------+------------------------+--------------+
|  0.0.0.0/0|  All outbound traffic  |  -1          |
+-----------+------------------------+--------------+
```

**Interpretation**:
- ✅ All traffic (-1 = all protocols) allowed to 0.0.0.0/0
- ❌ If restricted → instance can't download packages or reach RDS

**Result**: ✅ Egress allows all traffic

---

## Layer 4: Test Network Connectivity

### Step 4.1: Attempt HTTP Connection with Verbose Output

**Why**: Test if we can actually connect to port 80. The error message tells us whether it's a timeout (firewall) or connection refused (app not listening).

```bash
curl -v --connect-timeout 5 http://3.95.61.19/init 2>&1
```

**Actual Output**:
```
*   Trying 3.95.61.19:80...
* Connection timed out after 5002 milliseconds
* closing connection #0
curl: (28) Connection timed out after 5002 milliseconds
```

**Interpretation**:
- ❌ Connection timeout = packets not reaching the server OR nothing listening
- Since network layers 1-3 all passed, the issue is likely **application layer**
- The instance either:
  - Has no process listening on port 80
  - Process bound to 127.0.0.1 instead of 0.0.0.0
  - Firewall on the OS level (firewalld) blocking the port

**Result**: ❌ Connection times out - suggests application issue, not network issue

---

## Layer 5: Check EC2 Console Output (Critical Step)

### Step 5.1: Get Instance Console Output

**Why**: This is the **fastest way to diagnose user-data and boot issues**. Console output shows all system messages including cloud-init execution, package installation, and systemd service starts.

```bash
aws ec2 get-console-output \
  --instance-id i-05e2273d23d9c69ca \
  --latest \
  --output text | tail -100
```

**Actual Output** (critical lines):
```
[   24.701234] cloud-init[1619]: Last metadata expiration check: 0:00:02 ago on Sat Jan  3 11:44:53 2026.
[   24.736497] cloud-init[1619]: Package python3-3.9.25-1.amzn2023.0.1.x86_64 is already installed.
[   24.743122] cloud-init[1619]: No match for argument: mysql
[   24.758090] cloud-init[1619]: Error: Unable to find a match: mysql
[   24.789968] cloud-init[1619]: 2026-01-03 11:44:55,139 - cc_scripts_user.py[WARNING]: Failed to run module scripts-user (scripts in /var/lib/cloud/instance/scripts)
[   24.790187] cloud-init[1619]: 2026-01-03 11:44:55,140 - util.py[WARNING]: Running module scripts-user (<module 'cloudinit.config.cc_scripts_user' from '/usr/lib/python3.9/site-packages/cloudinit/config/cc_scripts_user.py'>) failed
```

**Interpretation**:
- 🔴 **ROOT CAUSE FOUND**: `No match for argument: mysql`
- The user-data script tried to install: `dnf install -y python3 python3-pip mysql`
- The `mysql` package does not exist in Amazon Linux 2023 repositories
- Since the script has `set -e`, it exited immediately on this error
- This prevented:
  - Flask and pymysql from being installed
  - The systemd service from being created
  - The application from ever starting

**Why this matters**:
- In Amazon Linux 2023, the MySQL client package was renamed/removed
- The Flask app uses **PyMySQL** (a Python library), so we don't need the `mysql` CLI tool
- The incorrect package caused the entire bootstrap to fail

**Result**: 🎯 **Issue identified - user-data script failed on mysql package**

---

## Root Cause Summary

**User-data script failure due to non-existent package.**

The user-data script attempted to install the `mysql` package on Amazon Linux 2023:
```bash
dnf install -y python3 python3-pip mysql
```

**Problem**: The package `mysql` does not exist in Amazon Linux 2023 repositories. The correct package for MySQL client is `mariadb105` or similar, but **we don't need a MySQL client at all** since the Flask app uses the PyMySQL Python library to connect to RDS.

Because the script had `set -e` (exit on any error), when `dnf install` failed on the `mysql` package, the entire user-data script terminated. This prevented:
- Flask and pymysql from being installed
- The systemd service from being created
- The application from ever starting

---

## Fix Implementation

### Step 6.1: Edit User-Data Template

**Why**: Remove the non-existent `mysql` package and add verification steps to catch failures early.

**File**: `templates/user_data.sh.tftpl`

**Changes Made**:

1. **Improved error handling**:
```diff
-set -e
+set -euo pipefail
```
- Added `-u` to catch undefined variable usage
- Added `-o pipefail` to catch errors in piped commands

2. **Removed mysql package**:
```diff
-dnf install -y python3 python3-pip mysql
+dnf install -y python3 python3-pip
```

3. **Added Python verification**:
```bash
# Verify Python installation
echo "$(date '+%Y-%m-%d %H:%M:%S') - Verifying Python..."
python3 --version
pip3 --version
```

4. **Added Flask/pymysql verification**:
```bash
# Verify Flask installation
echo "$(date '+%Y-%m-%d %H:%M:%S') - Verifying Flask and pymysql..."
python3 -c "import flask; print('Flask version:', flask.__version__)"
python3 -c "import pymysql; print('pymysql imported successfully')"
```

5. **Enhanced service verification**:
```diff
-sleep 5
+sleep 10

 if systemctl is-active --quiet notes-app; then
     echo "$(date '+%Y-%m-%d %H:%M:%S') - Notes App service started successfully!"
+
+    # Verify port 80 is listening
+    sleep 2
+    if ss -lntp | grep -q ':80'; then
+        echo "$(date '+%Y-%m-%d %H:%M:%S') - Port 80 is listening!"
+    else
+        echo "$(date '+%Y-%m-%d %H:%M:%S') - WARNING: Port 80 not listening yet"
+        ss -lntp || true
+    fi
 else
-    echo "$(date '+%Y-%m-%d %H:%M:%S') - WARNING: Notes App service may have failed to start"
+    echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: Notes App service failed to start!"
     systemctl status notes-app --no-pager || true
+    journalctl -u notes-app -n 50 --no-pager || true
 fi
```

---

### Step 6.2: Validate Terraform Configuration

**Why**: Ensure Terraform detects the user-data change and will recreate the instance.

```bash
terraform plan
```

**Expected Output**:
```
# aws_instance.web will be updated in-place
  ~ resource "aws_instance" "web" {
      ~ user_data = "d0d71d82e722dc8cb34815af5b963ad1d82c379e" -> "d301db5c0ad908cdeee3a182548f2485b989be12"
    }
```

**Interpretation**:
- Terraform shows user_data hash has changed
- The instance will be replaced (user-data changes require recreation)

---

### Step 6.3: Destroy Failed Instance

**Why**: User-data only runs on instance creation. We must destroy and recreate the instance to apply the fix.

```bash
terraform destroy -target=aws_instance.web -auto-approve
```

**Output**:
```
aws_instance.web: Destroying... [id=i-05e2273d23d9c69ca]
aws_instance.web: Still destroying... [id=i-05e2273d23d9c69ca, 00m10s elapsed]
aws_instance.web: Still destroying... [id=i-05e2273d23d9c69ca, 00m20s elapsed]
...
aws_instance.web: Destruction complete after 1m11s

Destroy complete! Resources: 1 destroyed.
```

**Interpretation**:
- Instance `i-05e2273d23d9c69ca` destroyed
- EBS volumes deleted (delete_on_termination = true)
- Public IP released

---

### Step 6.4: Create New Instance with Fixed User-Data

**Why**: Apply the fixed user-data script to a fresh instance.

```bash
terraform apply -auto-approve
```

**Output**:
```
aws_instance.web: Creating...
aws_instance.web: Still creating... [00m10s elapsed]
aws_instance.web: Creation complete after 14s [id=i-04e34f2033400d4f0]

Apply complete! Resources: 1 added, 0 changed, 0 destroyed.

Outputs:

ec2_instance_id = "i-04e34f2033400d4f0"
ec2_public_ip = "3.85.10.218"
app_url = "http://3.85.10.218"
```

**New Instance Details**:
- Instance ID: `i-04e34f2033400d4f0`
- Public IP: `3.85.10.218`
- Now need to wait for cloud-init to complete (2-3 minutes)

---

### Step 6.5: Wait for Cloud-Init to Complete

**Why**: User-data takes time to execute (package updates, installations, service setup). Must wait before testing.

```bash
# Wait 2 minutes for cloud-init to complete
sleep 120
```

**What's happening during this time**:
1. Package repositories updated
2. python3, python3-pip installed
3. Flask and pymysql pip packages installed
4. Application files created in /opt/notes-app
5. Systemd service created and started
6. Flask binds to port 80

---

## Post-Fix Verification

### Step 7.1: Test Health Endpoint

**Why**: Verify the Flask application is responding to HTTP requests.

```bash
curl -v --connect-timeout 10 http://3.85.10.218/health 2>&1
```

**Actual Output**:
```
*   Trying 3.85.10.218:80...
* Connected to 3.85.10.218 (3.85.10.218) port 80
* using HTTP/1.x
> GET /health HTTP/1.1
> Host: 3.85.10.218
> User-Agent: curl/8.14.1
> Accept: */*
>
< HTTP/1.1 200 OK
< Server: Werkzeug/3.1.4 Python/3.9.25
< Date: Sat, 03 Jan 2026 12:10:00 GMT
< Content-Type: application/json
< Content-Length: 21
< Connection: close
<
{"status":"healthy"}
```

**Interpretation**:
- ✅ Connection established successfully
- ✅ HTTP 200 OK response
- ✅ Flask/Werkzeug server running
- ✅ Application responding correctly

---

### Step 7.2: Initialize Database Table

**Why**: Test the /init endpoint which creates the notes table in RDS. This verifies EC2→RDS connectivity, Secrets Manager access, and database permissions.

```bash
curl http://3.85.10.218/init
```

**Actual Output**:
```json
{
  "message": "Notes table created/verified successfully",
  "status": "success"
}
```

**Interpretation**:
- ✅ EC2 successfully retrieved credentials from Secrets Manager
- ✅ Security group allows EC2→RDS connection on port 3306
- ✅ IAM role has correct permissions for secretsmanager:GetSecretValue
- ✅ RDS is accepting connections
- ✅ Database table created successfully

**What this proves**:
1. IAM instance profile is attached to EC2
2. Secrets Manager secret exists and is readable
3. RDS security group has SG-to-SG reference rule working
4. Network path from EC2 to RDS is functional
5. Database credentials in secret are valid

---

### Step 7.3: Add Test Notes

**Why**: Verify INSERT operations work (write path to database).

```bash
curl "http://3.85.10.218/add?note=First%20note%20from%20lab"
```

**Actual Output**:
```json
{
  "message": "Note added with ID 1",
  "note_id": 1,
  "status": "success"
}
```

```bash
curl "http://3.85.10.218/add?note=Second%20note%20testing%20EC2%20to%20RDS"
```

**Actual Output**:
```json
{
  "message": "Note added with ID 2",
  "note_id": 2,
  "status": "success"
}
```

```bash
curl "http://3.85.10.218/add?note=Troubleshooting%20complete"
```

**Actual Output**:
```json
{
  "message": "Note added with ID 3",
  "note_id": 3,
  "status": "success"
}
```

**Interpretation**:
- ✅ Database writes working
- ✅ Auto-increment ID working correctly
- ✅ Connection pooling/reuse working (multiple requests succeed)

---

### Step 7.4: List All Notes

**Why**: Verify SELECT operations work (read path from database).

```bash
curl http://3.85.10.218/list
```

**Actual Output**:
```json
{
  "count": 3,
  "notes": [
    {
      "content": "First note from lab",
      "created_at": "2026-01-03 12:10:16",
      "id": 1
    },
    {
      "content": "Second note testing EC2 to RDS",
      "created_at": "2026-01-03 12:10:16",
      "id": 2
    },
    {
      "content": "Troubleshooting complete",
      "created_at": "2026-01-03 12:10:16",
      "id": 3
    }
  ],
  "status": "success"
}
```

**Interpretation**:
- ✅ All notes retrieved successfully
- ✅ Data persisted correctly in RDS
- ✅ Timestamps recorded
- ✅ Full read/write cycle verified

---

### Step 7.5: Verify Console Output Shows Successful Bootstrap

**Why**: Confirm that the fixed user-data script completed successfully with all verification steps passing.

```bash
aws ec2 get-console-output \
  --instance-id i-04e34f2033400d4f0 \
  --latest \
  --output text | tail -50
```

**Actual Output** (key lines):
```
[   28.863375] cloud-init[1591]: Successfully installed blinker-1.9.0 click-8.1.8 flask-3.1.2 importlib-metadata-8.7.1 itsdangerous-2.2.0 jinja2-3.1.6 markupsafe-3.0.3 pymysql-1.1.2 werkzeug-3.1.4 zipp-3.23.0
[   29.087700] cloud-init[1591]: 2026-01-03 12:08:08 - Verifying Flask and pymysql...
[   29.244641] cloud-init[1591]: Flask version: 3.1.2
[   29.357756] cloud-init[1591]: pymysql imported successfully
[   29.371172] cloud-init[1591]: 2026-01-03 12:08:08 - Creating Flask application...
[   29.377385] cloud-init[1591]: 2026-01-03 12:08:08 - Creating systemd service...
[   29.382242] cloud-init[1591]: 2026-01-03 12:08:08 - Starting Notes App service...
[   39.956421] cloud-init[1591]: 2026-01-03 12:08:19 - Notes App service started successfully!
[   41.990916] cloud-init[1591]: 2026-01-03 12:08:21 - Port 80 is listening!
[   41.993187] cloud-init[1591]: 2026-01-03 12:08:21 - Setup complete!
```

**Interpretation**:
- ✅ No "mysql" package error
- ✅ Flask 3.1.2 installed successfully
- ✅ pymysql imported without errors
- ✅ Application created
- ✅ Systemd service started
- ✅ Port 80 confirmed listening
- ✅ Bootstrap completed successfully

**Timeline**:
- T+8s: Package installation
- T+19s: Service started
- T+21s: Port 80 listening confirmed

---

## Summary of All Tests Passed ✅

| Test | Command | Result |
|------|---------|--------|
| **Network Layer** |
| EC2 running with public IP | `aws ec2 describe-instances --instance-ids i-04e34f2033400d4f0` | ✅ Pass |
| Route table has IGW | `aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=subnet-..."` | ✅ Pass |
| SG allows port 80 | `aws ec2 describe-security-group-rules --filters "Name=group-id,Values=sg-..."` | ✅ Pass |
| **Application Layer** |
| HTTP connectivity | `curl -v http://3.85.10.218/health` | ✅ Pass |
| Health endpoint | `curl http://3.85.10.218/health` | ✅ Pass |
| Database init | `curl http://3.85.10.218/init` | ✅ Pass |
| Insert operations | `curl "http://3.85.10.218/add?note=test"` | ✅ Pass |
| Select operations | `curl http://3.85.10.218/list` | ✅ Pass |
| **Security Layer** |
| Secrets Manager access | Verified via /init success | ✅ Pass |
| EC2→RDS SG-to-SG | Verified via database connection | ✅ Pass |
| IAM instance profile | Verified via secret retrieval | ✅ Pass |

---

## Key Lessons Learned

### 1. Error Code Interpretation
**`curl: (28) Connection timed out`** means one of two things:
- Packets are being dropped (firewall/SG blocking)
- Nothing is listening on the port

**Different from `Connection refused`** (port 22, 3306 when closed):
- Server actively rejecting connections
- Service not running but port is reachable

### 2. Diagnostic Order Matters
**Follow the OSI model bottom-up**:
1. ✅ Layer 3: Check instance networking (IP, subnet, VPC)
2. ✅ Layer 3: Verify route tables and IGW
3. ✅ Layer 4: Check security groups (port rules)
4. ✅ Layer 4: Test connectivity with curl/netcat
5. 🎯 Layer 7: Check application logs (console output)

**Why this order**:
- Eliminates infrastructure issues first
- Narrows down to application-specific problems
- Saves time by not diving into application debugging when network is broken

### 3. Console Output is Your Best Friend
**For user-data/boot issues**, `aws ec2 get-console-output` shows:
- Package installation success/failure
- Cloud-init execution logs
- Systemd service starts/failures
- Custom echo statements from user-data

**Critical for diagnosing**:
- dnf install errors
- pip install failures
- Service crashes
- Script syntax errors

### 4. Amazon Linux 2023 Package Differences
**AL2023 is NOT AL2**:
- Different package repository
- Different package names
- Different default packages

**Always verify before assuming**:
```bash
# Search for package before using in user-data
dnf search mysql
```

**Common gotchas**:
- `mysql` → doesn't exist (use `mariadb105-server` or Python library)
- Some Python libraries need `python3-devel` for compilation
- Package versions may differ

### 5. User-Data Execution Model
**User-data runs ONCE on first boot**:
- Cannot be re-run by changing user-data hash
- Requires instance replacement (terminate + create new)
- Stored in instance metadata (visible in Terraform state)

**Implications**:
- `terraform apply` with changed user-data → instance replacement
- No "re-run user-data" button in AWS console
- Must destroy/create to apply fixes

### 6. Bash `set -e` Behavior
**`set -e` causes immediate exit on ANY command failure**:
- Good: Fails fast, prevents cascading errors
- Bad: One failed package kills entire script

**Best practice**:
```bash
set -euo pipefail  # -u = undefined vars, -o pipefail = catch pipe errors

# For non-critical commands, use || true
systemctl status app || true  # Won't exit script if service not running
```

### 7. Verification at Each Step
**Why add verification commands**:
- Catches errors immediately (fail fast)
- Provides clear error messages in console output
- Easier to debug than "silently failed"

**Example**:
```bash
dnf install -y python3
python3 --version || { echo "ERROR: Python not installed"; exit 1; }
```

### 8. Security Group SG-to-SG References
**Why use SG references instead of CIDRs**:
- Dynamic membership (new instances auto-allowed)
- No IP management needed
- Survives instance recreation/IP changes
- Explicit trust relationships

**Verification**:
```bash
# Check for SG reference (SourceSG populated, SourceCIDR null)
aws ec2 describe-security-group-rules --filters "Name=group-id,Values=<RDS_SG>"
# Look for: ReferencedGroupInfo.GroupId (not CidrIpv4)
```

### 9. IAM Instance Profiles for AWS API Access
**Never use static credentials in user-data**:
- ❌ Hardcoded access keys → visible in logs, state files
- ✅ Instance profile → automatic credential rotation, scoped permissions

**Verification**:
```bash
# From EC2 instance
curl http://169.254.169.254/latest/meta-data/iam/security-credentials/
# Should return role name

# Test AWS CLI without credentials
aws sts get-caller-identity
```

### 10. Wait Times for Cloud-Init
**Typical timeline after instance launch**:
- T+0: Instance state = running
- T+10s: Cloud-init starts
- T+30s: User-data execution begins
- T+1-3min: Packages installed
- T+2-4min: Application running

**Always wait 2-3 minutes** before testing application endpoints.

---

## Troubleshooting Framework for Future Use

When facing "port unreachable" issues on EC2, follow this exact sequence:

### 1. Get Initial Facts
```bash
# Instance ID, IP, SG from Terraform output
terraform output
```

### 2. Check Layer 3 (Network)
```bash
aws ec2 describe-instances --instance-ids <ID>
# Verify: State=running, PublicIP exists, correct Subnet, correct SG
```

### 3. Check Routes
```bash
aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=<SUBNET>"
# Verify: 0.0.0.0/0 → igw-xxx exists
```

### 4. Check Security Groups
```bash
aws ec2 describe-security-group-rules --filters "Name=group-id,Values=<SG>"
# Verify: Port 80 ingress allowed, all egress allowed
```

### 5. Test Connectivity
```bash
curl -v --connect-timeout 10 http://<IP>:<PORT>
# If timeout → check application
# If refused → port not listening
```

### 6. Check Console Output (CRITICAL)
```bash
aws ec2 get-console-output --instance-id <ID> --latest --output text | tail -100
# Look for: dnf errors, pip errors, service failures
```

### 7. SSH In (If Enabled)
```bash
# Save the private key (only once)
terraform output -raw ssh_private_key > ec2-ssh-key.pem
chmod 400 ec2-ssh-key.pem

# Connect to EC2
ssh -i ec2-ssh-key.pem ec2-user@$(terraform output -raw ec2_public_ip)

# Once connected, check services
sudo systemctl status <service>
sudo journalctl -u <service> -n 100
sudo ss -lntp  # Check listening ports
```

---

## Current Infrastructure Status

| Component | Value |
|-----------|-------|
| **EC2 Instance** | `i-04e34f2033400d4f0` |
| **Public IP** | `3.85.10.218` |
| **Application URL** | http://3.85.10.218 |
| **RDS Endpoint** | `ec2-rds-notes-lab-mysql.czwskgwokzak.us-east-1.rds.amazonaws.com:3306` |
| **Status** | ✅ Running and verified |
| **Security** | SG-to-SG reference, Secrets Manager, IAM role, IMDSv2 |
| **Last Verified** | 2026-01-03 12:10 UTC |

---

## Quick Reference: Common Commands

```bash
# Get instance status
aws ec2 describe-instances --instance-ids $(terraform output -raw ec2_instance_id)

# Get console output
aws ec2 get-console-output --instance-id $(terraform output -raw ec2_instance_id) --latest --output text | tail -100

# Check RDS status
aws rds describe-db-instances --db-instance-identifier $(terraform output -raw rds_identifier)

# Verify SG rules
aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$(terraform output -raw ec2_security_group_id)"

# Test endpoints
curl http://$(terraform output -raw ec2_public_ip)/health
curl http://$(terraform output -raw ec2_public_ip)/init
curl http://$(terraform output -raw ec2_public_ip)/list
```
