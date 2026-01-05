# Lab 1b Runbook

## Overview

This runbook provides comprehensive diagnostic and troubleshooting procedures for Lab 1b. It includes:
- **Part 1**: Incident response procedures for database connection failures (when alarms trigger)
- **Part 2**: General troubleshooting for CloudWatch Logs, metrics, alarms, and monitoring components

---

# Part 1: Incident Response Procedures

## Quick Reference

**When to use these procedures:**
- CloudWatch alarm `lab-db-connection-errors` in ALARM state
- Application returns 500 errors on `/init`, `/add`, or `/list`
- Logs show `DB_CONNECTION_FAILURE` errors

**Common failure modes:**
1. **Credential Drift**: Secrets Manager password doesn't match RDS
2. **Network Isolation**: Security group rules removed or misconfigured
3. **DB Availability**: RDS instance stopped, rebooting, or unavailable

---

## Step 1: Check Alarm State

### Get current alarm status

```bash
aws cloudwatch describe-alarms \
  --alarm-name-prefix lab-db-connection \
  --query 'MetricAlarms[].{Name:AlarmName,State:StateValue,Reason:StateReason,UpdatedTime:StateUpdatedTimestamp}' \
  --output table
```

**Expected output:**
```
---------------------------------------------------------
|                   DescribeAlarms                       |
+---------------------------+--------+-------------------+
|          Name             | State  |    Reason         |
+---------------------------+--------+-------------------+
|  lab-db-connection-errors | ALARM  | Threshold Crossed |
+---------------------------+--------+-------------------+
```

**Interpretation:**
- `ALARM`: >= 3 connection errors in past 5 minutes
- `OK`: No errors or below threshold
- `INSUFFICIENT_DATA`: No metric data (app not running or no errors yet)

---

## Step 2: Check CloudWatch Logs for DB Connection Errors

### View recent DB connection failure logs

```bash
aws logs filter-log-events \
  --log-group-name /aws/ec2/lab-rds-app \
  --filter-pattern "DB_CONNECTION_FAILURE" \
  --start-time $(date -u -d '10 minutes ago' +%s)000 \
  --query 'events[].message' \
  --output text
```

**What to look for:**

**Credential errors:**
```
DB_CONNECTION_FAILURE OperationalError: (1045, "Access denied for user 'dbadmin'@'...' (using password: YES)")
```
→ **Root cause: Credential drift** (Go to Step 6a)

**Network errors:**
```
DB_CONNECTION_FAILURE OperationalError: (2003, "Can't connect to MySQL server on '...' (110)")
DB_CONNECTION_FAILURE TimeoutError: timed out
```
→ **Root cause: Network isolation** (Go to Step 6b)

**Database unavailable:**
```
DB_CONNECTION_FAILURE OperationalError: (2003, "Can't connect to MySQL server on '...' (111)")
```
→ **Root cause: DB not running** (Go to Step 6c)

---

## Step 3: Verify Parameter Store Values

### Get all DB parameters

```bash
aws ssm get-parameters \
  --names /lab/db/endpoint /lab/db/port /lab/db/name \
  --with-decryption \
  --query 'Parameters[].{Name:Name,Value:Value}' \
  --output table
```

**Expected output:**
```
------------------------------------------------------------
|                     GetParameters                        |
+----------------------+-----------------------------------+
|         Name         |              Value                |
+----------------------+-----------------------------------+
|  /lab/db/endpoint    |  xxx.rds.amazonaws.com            |
|  /lab/db/port        |  3306                             |
|  /lab/db/name        |  notesdb                          |
+----------------------+-----------------------------------+
```

**Validation:**
- Endpoint should be a valid RDS endpoint (format: `<id>.<region>.rds.amazonaws.com`)
- Port should be `3306`
- DB name should be `notesdb` (or your configured value)

---

## Step 4: Verify Secrets Manager Credentials

### Get secret value (includes password)

```bash
aws secretsmanager get-secret-value \
  --secret-id lab/rds/mysql \
  --query SecretString \
  --output text | jq .
```

**Expected output:**
```json
{
  "username": "dbadmin",
  "password": "xxxxxxxxxxxxxxxxxxxxxx",
  "host": "xxx.rds.amazonaws.com",
  "port": 3306,
  "dbname": "notesdb"
}
```

**Validation:**
- `host` should match Parameter Store `/lab/db/endpoint`
- `port` and `dbname` should match Parameter Store values
- `password` should be a 24-character random string

---

## Step 5: Check RDS Instance Status

### Get RDS instance details

```bash
aws rds describe-db-instances \
  --query 'DBInstances[?DBInstanceIdentifier==`ec2-rds-notes-lab-mysql`].{Status:DBInstanceStatus,Endpoint:Endpoint.Address,Port:Endpoint.Port,Engine:Engine}' \
  --output table
```

**Expected output:**
```
-----------------------------------------------------------
|                DescribeDBInstances                      |
+---------------------------+--------+-------+------------+
|         Endpoint          | Engine | Port  |   Status   |
+---------------------------+--------+-------+------------+
|  xxx.rds.amazonaws.com    | mysql  | 3306  | available  |
+---------------------------+--------+-------+------------+
```

**Status meanings:**
- `available`: RDS is running and accepting connections ✅
- `stopped`: RDS manually stopped (Go to Step 6c)
- `starting`, `rebooting`: Wait for status to become `available`
- `backing-up`, `modifying`: Temporary state, wait for completion
- `failed`, `inaccessible-encryption-credentials`: Critical failure, escalate

---

## Step 6: Recovery Actions

### Scenario 6a: Credential Drift

**Symptoms:**
- Logs show: `Access denied for user 'dbadmin'`
- RDS status: `available`
- Network tests: Pass

**Root cause:** Password in Secrets Manager doesn't match RDS master password

**Recovery steps:**

1. **Get current Secrets Manager password:**
```bash
CURRENT_PASS=$(aws secretsmanager get-secret-value \
  --secret-id lab/rds/mysql \
  --query SecretString \
  --output text | jq -r .password)
echo "Current SM password length: ${#CURRENT_PASS}"
```

2. **Reset RDS master password to match Secrets Manager:**
```bash
aws rds modify-db-instance \
  --db-instance-identifier ec2-rds-notes-lab-mysql \
  --master-user-password "$CURRENT_PASS" \
  --apply-immediately
```

3. **Wait for modification to complete (1-2 minutes):**
```bash
aws rds describe-db-instances \
  --db-instance-identifier ec2-rds-notes-lab-mysql \
  --query 'DBInstances[0].{Status:DBInstanceStatus,PendingModifications:PendingModifiedValues}' \
  --output json
```

Wait until `PendingModifiedValues` is empty and `Status` is `available`.

4. **Test connection from EC2:**
```bash
curl http://$(terraform output -raw ec2_public_ip)/init
```

Expected: `{"status":"success",...}`

---

### Scenario 6b: Network Isolation

**Symptoms:**
- Logs show: `Can't connect to MySQL server` or `timed out`
- RDS status: `available`
- Credential test: N/A (can't reach RDS to test)

**Root cause:** Security group rule missing or EC2 instance not in allowed SG

**Recovery steps:**

1. **Check RDS security group ingress rules:**
```bash
RDS_SG=$(aws rds describe-db-instances \
  --db-instance-identifier ec2-rds-notes-lab-mysql \
  --query 'DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId' \
  --output text)

aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=$RDS_SG" \
  --query 'SecurityGroupRules[?IsEgress==`false`].{Port:FromPort,SourceSG:ReferencedGroupInfo.GroupId,CIDR:CidrIpv4}' \
  --output table
```

**Expected:**
```
--------------------------------------------
|       DescribeSecurityGroupRules         |
+------------+-------------------+---------+
|    CIDR    |       Port        | SourceSG|
+------------+-------------------+---------+
|  None      |  3306             | sg-xxx  |
+------------+-------------------+---------+
```

**Validation:**
- Port should be `3306`
- `SourceSG` should be the EC2 security group (not CIDR)
- `CIDR` should be `None` (using SG-to-SG reference)

2. **If rule is missing, recreate it:**

```bash
EC2_SG=$(terraform output -raw ec2_security_group_id)
RDS_SG=$(terraform output -raw rds_security_group_id)

aws ec2 authorize-security-group-ingress \
  --group-id "$RDS_SG" \
  --ip-permissions IpProtocol=tcp,FromPort=3306,ToPort=3306,UserIdGroupPairs="[{GroupId=$EC2_SG,Description='MySQL from EC2 security group'}]"
```

3. **Verify rule creation:**
```bash
aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=$RDS_SG" \
  --query 'SecurityGroupRules[?IsEgress==`false`]' \
  --output table
```

4. **Test connection immediately (no wait needed):**
```bash
curl http://$(terraform output -raw ec2_public_ip)/init
```

---

### Scenario 6c: Database Unavailable

**Symptoms:**
- Logs show: `Can't connect to MySQL server on '...' (111)`
- RDS status: `stopped` or not `available`

**Root cause:** RDS instance manually stopped or crashed

**Recovery steps:**

1. **Start RDS instance:**
```bash
aws rds start-db-instance \
  --db-instance-identifier ec2-rds-notes-lab-mysql
```

**Expected output:**
```json
{
  "DBInstance": {
    "DBInstanceIdentifier": "ec2-rds-notes-lab-mysql",
    "DBInstanceStatus": "starting",
    ...
  }
}
```

2. **Wait for RDS to become available (3-5 minutes):**
```bash
aws rds wait db-instance-available \
  --db-instance-identifier ec2-rds-notes-lab-mysql

echo "RDS is now available!"
```

**Alternative: Poll status every 30 seconds:**
```bash
while true; do
  STATUS=$(aws rds describe-db-instances \
    --db-instance-identifier ec2-rds-notes-lab-mysql \
    --query 'DBInstances[0].DBInstanceStatus' \
    --output text)
  echo "$(date '+%H:%M:%S') - RDS status: $STATUS"
  [ "$STATUS" = "available" ] && break
  sleep 30
done
```

3. **Test connection:**
```bash
curl http://$(terraform output -raw ec2_public_ip)/init
```

---

## Step 7: Verify Application Endpoints

### Test all endpoints after recovery

```bash
EC2_IP=$(terraform output -raw ec2_public_ip)

# Health check
echo "=== Health Check ==="
curl http://$EC2_IP/health

# Initialize table (if not already done)
echo -e "\n=== Initialize DB ==="
curl http://$EC2_IP/init

# Add test note
echo -e "\n=== Add Note ==="
curl "http://$EC2_IP/add?note=Recovery%20test%20$(date +%s)"

# List all notes
echo -e "\n=== List Notes ==="
curl http://$EC2_IP/list | jq .
```

**Expected output:**
- Health: `{"status":"healthy"}`
- Init: `{"status":"success",...}`
- Add: `{"status":"success","note_id":N}`
- List: `{"status":"success","count":N,"notes":[...]}`

---

## Step 8: Confirm Alarm Returns to OK

### Check alarm state after recovery

Wait 5-10 minutes for metric evaluation period to pass, then:

```bash
aws cloudwatch describe-alarms \
  --alarm-names lab-db-connection-errors \
  --query 'MetricAlarms[0].{State:StateValue,Reason:StateReason,UpdatedTime:StateUpdatedTimestamp}' \
  --output table
```

**Expected:**
```
-----------------------------------------------------------
|                   DescribeAlarms                        |
+------------------+---------------------+----------------+
|      Reason      |        State        |  UpdatedTime   |
+------------------+---------------------+----------------+
|  Threshold Crossed (no datapoints)   |  OK  | 2026-...  |
+------------------+---------------------+----------------+
```

**State meanings:**
- `OK`: No errors in evaluation period (success!)
- `ALARM`: Still seeing errors (repeat diagnosis)
- `INSUFFICIENT_DATA`: No new metric data (check if app is running)

---

## Step 9: Post-Incident Documentation

### Record incident details

1. **Get alarm history:**
```bash
aws cloudwatch describe-alarm-history \
  --alarm-name lab-db-connection-errors \
  --start-date $(date -u -d '1 hour ago' --iso-8601=seconds) \
  --max-records 20 \
  --query 'AlarmHistoryItems[].{Time:Timestamp,Type:HistoryItemType,Summary:HistorySummary}' \
  --output table
```

2. **Extract ERROR log entries from incident window:**
```bash
START_TIME=$(date -u -d '30 minutes ago' +%s)000
END_TIME=$(date -u +%s)000

aws logs filter-log-events \
  --log-group-name /aws/ec2/lab-rds-app \
  --filter-pattern "DB_CONNECTION_FAILURE" \
  --start-time $START_TIME \
  --end-time $END_TIME \
  --query 'events[].{Time:timestamp,Message:message}' \
  --output table > incident_logs.txt
```

3. **Document in incident report:**
- Start time: (from alarm history)
- End time: (when alarm returned to OK)
- Root cause: (6a/6b/6c)
- Recovery action taken
- Preventive measures

---

# Part 2: General Troubleshooting

This section covers Lab 1b specific issues related to CloudWatch Logs, metrics, alarms, and dual secret storage.

---

## Issue 1: CloudWatch Logs Not Appearing

**Symptom:**
- Log group `/aws/ec2/lab-rds-app` exists but has no log streams
- OR log streams exist but no recent events

**Diagnostic Steps:**

#### Step 1: Check log group exists
```bash
aws logs describe-log-groups \
  --log-group-name-prefix /aws/ec2/lab-rds-app
```

**Expected:** One log group with retention set to 7 days

#### Step 2: Check log streams
```bash
aws logs describe-log-streams \
  --log-group-name /aws/ec2/lab-rds-app \
  --order-by LastEventTime \
  --descending \
  --max-items 5
```

**Expected:** At least one stream named `{instance-id}/app.log` with recent `lastEventTimestamp`

#### Step 3: Check CloudWatch Agent status (on EC2)
```bash
# SSH to EC2 (save key first - only needed once)
terraform output -raw ssh_private_key > ec2-ssh-key.pem
chmod 400 ec2-ssh-key.pem
ssh -i ec2-ssh-key.pem ec2-user@$(terraform output -raw ec2_public_ip)

# Check agent status
sudo systemctl status amazon-cloudwatch-agent
```

**Expected:**
```
● amazon-cloudwatch-agent.service - Amazon CloudWatch Agent
   Loaded: loaded
   Active: active (running)
```

#### Step 4: Check agent logs
```bash
sudo tail -100 /opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log
```

**Look for errors:**
- `E! Failed to create log stream`: IAM permissions issue
- `E! Error occurred in DescribeLogStreams`: IAM permissions issue
- `AccessDeniedException`: Missing logs:CreateLogStream permission

**Root Causes & Fixes:**

**Cause A: Agent not installed**
- User-data failed during agent installation
- Check console output: `aws ec2 get-console-output --instance-id <id> --latest`
- Look for wget or rpm errors during agent install

**Fix:** Recreate EC2 instance (`terraform taint aws_instance.web && terraform apply`)

**Cause B: Agent not running**
```bash
sudo systemctl start amazon-cloudwatch-agent
sudo systemctl enable amazon-cloudwatch-agent
```

**Cause C: IAM permissions missing**

Check IAM policy:
```bash
aws iam get-policy \
  --policy-arn $(aws iam list-attached-role-policies \
    --role-name ec2-rds-notes-lab-ec2-role \
    --query 'AttachedPolicies[?PolicyName==`ec2-rds-notes-lab-cloudwatch-logs-access`].PolicyArn' \
    --output text) \
  --query 'Policy.Arn'
```

If missing, check Terraform apply completed successfully.

**Cause D: Agent configuration incorrect**

Check config file:
```bash
sudo cat /opt/aws/amazon-cloudwatch-agent/etc/cloudwatch-config.json
```

**Expected:**
```json
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/notes-app.log",
            "log_group_name": "/aws/ec2/lab-rds-app",
            "log_stream_name": "{instance_id}/app.log"
          }
        ]
      }
    }
  }
}
```

If incorrect, recreate EC2 instance.

---

## Issue 2: CloudWatch Alarm Stuck in INSUFFICIENT_DATA

**Symptom:**
- Alarm state: `INSUFFICIENT_DATA`
- Never transitions to OK or ALARM

**Diagnostic Steps:**

#### Step 1: Check metric data exists
```bash
aws cloudwatch get-metric-statistics \
  --namespace Lab/RDSApp \
  --metric-name DBConnectionErrors \
  --start-time $(date -u -d '1 hour ago' --iso-8601=seconds) \
  --end-time $(date -u --iso-8601=seconds) \
  --period 60 \
  --statistics Sum
```

**Expected:** Empty `Datapoints` array if no errors occurred (this is normal)

**Root Cause:** Alarm configured with `treat_missing_data = notBreaching`, so INSUFFICIENT_DATA means:
- No errors have occurred yet (good!)
- OR metric filter not capturing errors (bad)

#### Step 2: Test metric filter manually

Generate a connection error:
```bash
# Temporarily stop RDS
aws rds stop-db-instance --db-instance-identifier ec2-rds-notes-lab-mysql

# Wait 30 seconds for RDS to stop
sleep 30

# Trigger 5 connection attempts (should generate ERROR logs)
for i in {1..5}; do
  curl http://$(terraform output -raw ec2_public_ip)/list
  sleep 2
done

# Start RDS again
aws rds start-db-instance --db-instance-identifier ec2-rds-notes-lab-mysql
```

#### Step 3: Check ERROR logs appeared
```bash
aws logs filter-log-events \
  --log-group-name /aws/ec2/lab-rds-app \
  --filter-pattern "ERROR" \
  --start-time $(date -u -d '5 minutes ago' +%s)000
```

**Expected:** At least 5 ERROR messages containing "connection"

#### Step 4: Wait 5 minutes and check alarm
```bash
sleep 300

aws cloudwatch describe-alarms \
  --alarm-names lab-db-connection-errors \
  --query 'MetricAlarms[0].StateValue'
```

**Expected:** State transitions to `ALARM` then back to `OK` after 5 more minutes

**If still INSUFFICIENT_DATA:**

**Cause A: Metric filter pattern not matching**

Check metric filter:
```bash
aws logs describe-metric-filters \
  --log-group-name /aws/ec2/lab-rds-app
```

**Expected pattern:** `"DB_CONNECTION_FAILURE"`

This matches log lines like:
```
2026-01-03 12:00:00 - ERROR - DB_CONNECTION_FAILURE OperationalError: (2003, "Can't connect...")
```

**Cause B: Log format changed**

Check actual log format:
```bash
aws logs tail /aws/ec2/lab-rds-app --since 10m
```

Ensure ERROR logs contain the `DB_CONNECTION_FAILURE` token.

---

## Issue 3: Parameter Store Values Not Accessible

**Symptom:**
- `aws ssm get-parameter --name /lab/db/endpoint` returns `AccessDeniedException`

**Diagnostic Steps:**

#### Step 1: Verify parameters exist
```bash
aws ssm describe-parameters \
  --parameter-filters "Key=Name,Values=/lab/db/"
```

**Expected:** 3 parameters: endpoint, port, name

#### Step 2: Check IAM role has SSM permissions
```bash
aws iam get-policy-version \
  --policy-arn $(aws iam list-policies \
    --query 'Policies[?PolicyName==`ec2-rds-notes-lab-ssm-params-access`].Arn' \
    --output text) \
  --version-id v1 \
  --query 'PolicyVersion.Document.Statement'
```

**Expected:**
```json
[
  {
    "Sid": "GetDBParameters",
    "Effect": "Allow",
    "Action": ["ssm:GetParameter", "ssm:GetParameters"],
    "Resource": [
      "arn:aws:ssm:us-east-1:ACCOUNT:parameter/lab/db/endpoint",
      "arn:aws:ssm:us-east-1:ACCOUNT:parameter/lab/db/port",
      "arn:aws:ssm:us-east-1:ACCOUNT:parameter/lab/db/name"
    ]
  }
]
```

#### Step 3: Verify role attached to EC2
```bash
aws ec2 describe-instances \
  --instance-ids $(terraform output -raw ec2_instance_id) \
  --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn'
```

**Expected:** ARN containing `ec2-rds-notes-lab-ec2-profile`

**Fixes:**

**If parameters missing:** Run `terraform apply` to create them

**If IAM policy missing:** Run `terraform apply` to attach policy to role

**If role not attached to EC2:** Recreate EC2 instance

---

## Issue 4: Metric Filter Not Creating Data Points

**Symptom:**
- ERROR logs exist in CloudWatch Logs
- But metric `DBConnectionErrors` has no data points

**Diagnostic Steps:**

#### Step 1: Verify metric filter exists
```bash
aws logs describe-metric-filters \
  --log-group-name /aws/ec2/lab-rds-app \
  --query 'metricFilters[].{Name:filterName,Pattern:filterPattern,MetricName:metricTransformations[0].metricName}'
```

**Expected:**
```json
[
  {
    "Name": "ec2-rds-notes-lab-db-connection-errors",
    "Pattern": "\"DB_CONNECTION_FAILURE\"",
    "MetricName": "DBConnectionErrors"
  }
]
```

#### Step 2: Test pattern manually

Get a sample ERROR log:
```bash
LOG_LINE=$(aws logs filter-log-events \
  --log-group-name /aws/ec2/lab-rds-app \
  --filter-pattern "ERROR" \
  --max-items 1 \
  --query 'events[0].message' \
  --output text)

echo "$LOG_LINE"
```

**Example:**
```
2026-01-03 12:00:00 - ERROR - DB_CONNECTION_FAILURE OperationalError: (2003, "Can't connect...")
```

#### Step 3: Verify pattern matches

The pattern `"DB_CONNECTION_FAILURE"` performs a simple literal string match.

This matches any log line containing the exact text `DB_CONNECTION_FAILURE`, which is emitted by the application when database connection failures occur.

**Advantages of this approach:**
- Simple and reliable (no complex field parsing)
- Works with any log format
- No delimiter sensitivity
- Stable token guaranteed by application code

**If metric filter not working:** Verify the application is actually emitting the `DB_CONNECTION_FAILURE` token in error logs

---

## Issue 5: SNS Email Not Received

**Symptom:**
- Alarm shows ALARM state in console
- No email received at subscribed address

**Common Cause:** Alarm is already in ALARM state - emails only sent on state **transitions**

#### Understanding CloudWatch Alarm Email Behavior

CloudWatch alarms send emails only when **state changes**:
- ✅ **OK → ALARM:** Sends ALARM email
- ✅ **ALARM → OK:** Sends OK email
- ❌ **ALARM → ALARM:** No email (already in alarm state)
- ❌ **OK → OK:** No email (no change)

**If you trigger errors but get no email, the alarm is likely already in ALARM state.**

#### Step 1: Check current alarm state
```bash
aws cloudwatch describe-alarms \
  --alarm-names lab-db-connection-errors \
  --query 'MetricAlarms[0].{State:StateValue,Since:StateUpdatedTimestamp,Reason:StateReason}' \
  --output table
```

**If State = ALARM:**
- The alarm won't send another email until it transitions back to OK first
- You need to fix the issue, wait for OK state, then break it again to get a new ALARM email

#### Step 2: Verify subscription status
```bash
# Check if subscription exists and is confirmed
aws sns list-subscriptions-by-topic \
  --topic-arn $(terraform output -raw sns_topic_arn) \
  --query 'Subscriptions[*].{Endpoint:Endpoint,Status:SubscriptionArn}' \
  --output table
```

**Expected outputs:**

**If alert_email variable was set:**
```
Endpoint: your@email.com
Status: arn:aws:sns:...:lab-db-incidents:xxxxx (confirmed)
```

**If alert_email was NOT set:**
```
(empty - no subscriptions)
```

**If PendingConfirmation:**
- Check email inbox for "AWS Notification - Subscription Confirmation"
- Click the confirmation link
- Status will change from "PendingConfirmation" to subscription ARN

#### Step 3: Subscribe if not subscribed
```bash
# Option 1: Use Terraform (recommended)
terraform apply -var="alert_email=your@email.com"
# Then check email and confirm

# Option 2: Manual AWS CLI subscription
SNS_TOPIC=$(terraform output -raw sns_topic_arn)
aws sns subscribe \
  --topic-arn $SNS_TOPIC \
  --protocol email \
  --notification-endpoint your-email@example.com
```

**Expected:** Email with subject "AWS Notification - Subscription Confirmation"

#### Step 4: Test email delivery with SNS publish
```bash
# Send a test message directly to SNS
aws sns publish \
  --topic-arn $(terraform output -raw sns_topic_arn) \
  --subject "TEST: Lab DB Incidents" \
  --message "Test notification to verify email delivery is working."
```

**Expected:** Email arrives within 1-2 minutes

**If test email arrives but alarm emails don't:**
- Check spam/junk folder for AWS CloudWatch emails
- Add `no-reply@sns.amazonaws.com` to safe senders
- Check email filters blocking "AWS Notifications"

#### Step 5: Full alarm cycle test (to receive both OK and ALARM emails)

**5a. Ensure alarm is in OK state first:**
```bash
# Restore database connectivity if broken
RDS_SG=$(terraform output -raw rds_security_group_id)
EC2_SG=$(terraform output -raw ec2_security_group_id)

aws ec2 authorize-security-group-ingress \
  --group-id "$RDS_SG" \
  --ip-permissions IpProtocol=tcp,FromPort=3306,ToPort=3306,UserIdGroupPairs="[{GroupId=$EC2_SG,Description='MySQL from EC2 security group'}]"

# Wait 5-10 minutes for alarm to return to OK
aws cloudwatch describe-alarms \
  --alarm-names lab-db-connection-errors \
  --query 'MetricAlarms[0].StateValue' \
  --output text
```

**Expected:** After 5-10 minutes, state changes to "OK"
**Email received:** "OK: lab-db-connection-errors in US East (N. Virginia)"

**5b. Trigger alarm (once in OK state):**
```bash
# Get RDS security group rule ID
RDS_SG=$(terraform output -raw rds_security_group_id)
RULE_ID=$(aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=$RDS_SG" \
  --query 'SecurityGroupRules[?IsEgress==`false`].SecurityGroupRuleId' \
  --output text)

# Remove rule to trigger errors
aws ec2 revoke-security-group-ingress \
  --group-id $RDS_SG \
  --security-group-rule-ids $RULE_ID

# Generate 5+ errors (triggers alarm when >= 3 in 5 minutes)
for i in {1..5}; do
  curl http://$(terraform output -raw ec2_public_ip)/list
  sleep 2
done

# Wait 5-7 minutes for alarm to trigger
sleep 420

# Check alarm state
aws cloudwatch describe-alarms \
  --alarm-names lab-db-connection-errors \
  --query 'MetricAlarms[0].StateValue' \
  --output text
```

**Expected:** State changes to "ALARM"
**Email received:** "ALARM: lab-db-connection-errors in US East (N. Virginia)"

#### Step 6: Verify alarm history shows email delivery
```bash
aws cloudwatch describe-alarm-history \
  --alarm-name lab-db-connection-errors \
  --max-records 5 \
  --query 'AlarmHistoryItems[*].{Time:Timestamp,Type:HistoryItemType,Summary:HistorySummary}' \
  --output table
```

**Expected:** Should show entries like:
```
Successfully executed action arn:aws:sns:us-east-1:...:lab-db-incidents
```

If these entries exist, SNS was notified. If email still not received, it's an email delivery issue (spam filter, etc.)

#### Common Email Delivery Issues

**Issue:** Emails going to spam/junk folder
- **Solution:** Add `no-reply@sns.amazonaws.com` to safe senders list
- **Yahoo/Gmail:** Check "Promotions" or "Updates" tabs

**Issue:** Email provider blocking AWS notifications
- **Solution:** Check corporate email policies or use personal email

**Issue:** Subscription shows "PendingConfirmation"
- **Solution:** Check ALL email folders including spam for confirmation email
- If lost, delete subscription and recreate:
  ```bash
  aws sns unsubscribe --subscription-arn <ARN>
  terraform apply -var="alert_email=your@email.com"
  ```

**Issue:** Wrong email address subscribed
- **Solution:** Update tfvars and re-apply:
  ```bash
  terraform apply -var="alert_email=correct@email.com"
  ```

---

## Issue 6: Application Logging ERROR But No Errors Occurring

**Symptom:**
- CloudWatch Logs show ERROR level logs
- But application is working fine

**Diagnostic Steps:**

Check log context:
```bash
aws logs tail /aws/ec2/lab-rds-app --follow
```

**Possible causes:**

**Cause A: False positive from user input**

Example:
```
2026-01-03 12:00:00 - INFO - Added note: "This is a DB_CONNECTION_FAILURE test message"
```

Metric filter might match `DB_CONNECTION_FAILURE` in note content.

**Fix:** This is extremely unlikely since `DB_CONNECTION_FAILURE` is a specific technical token. However, if false positives occur, the application code should be updated to use an even more unique token.

**Cause B: Other ERROR-level logs**

Application might log other errors that don't relate to DB connections.

**Fix:** The current pattern `"DB_CONNECTION_FAILURE"` is already specific to database connection failures only. No change needed - this is the intended behavior.

---

## Lab 1a Issues (Still Applicable)

All Lab 1a troubleshooting steps still apply:

### Layer-by-Layer Diagnostic Order

1. ✅ **EC2 Network**: Instance running, public IP, correct subnet
2. ✅ **Route Tables**: IGW route exists for public subnet
3. ✅ **Security Groups**: Port 80 ingress, all egress, RDS SG-to-SG rule
4. ✅ **Application**: Service running, port 80 listening
5. ✅ **Secrets Manager**: Secret accessible from EC2
6. ✅ **RDS**: Instance available, endpoint reachable

See Lab 1a `RUNBOOK.md` for complete procedures.

---

## Common Lab 1b Commands

### Check All Monitoring Components

```bash
#!/bin/bash
# Lab 1b Health Check Script

echo "=== CloudWatch Logs ==="
aws logs describe-log-groups --log-group-name-prefix /aws/ec2/lab-rds-app

echo -e "\n=== Log Streams ==="
aws logs describe-log-streams \
  --log-group-name /aws/ec2/lab-rds-app \
  --order-by LastEventTime \
  --descending \
  --max-items 3

echo -e "\n=== Metric Filter ==="
aws logs describe-metric-filters --log-group-name /aws/ec2/lab-rds-app

echo -e "\n=== CloudWatch Alarm ==="
aws cloudwatch describe-alarms --alarm-names lab-db-connection-errors

echo -e "\n=== SNS Topic ==="
aws sns get-topic-attributes --topic-arn $(terraform output -raw sns_topic_arn)

echo -e "\n=== SSM Parameters ==="
aws ssm get-parameters --names /lab/db/endpoint /lab/db/port /lab/db/name

echo -e "\n=== Recent Logs ==="
aws logs tail /aws/ec2/lab-rds-app --since 5m
```

Save as `check_lab1b.sh` and run: `bash check_lab1b.sh`

---

## Emergency Recovery Commands

### Recreate CloudWatch Agent

```bash
# SSH to EC2 (save key if not already done)
terraform output -raw ssh_private_key > ec2-ssh-key.pem
chmod 400 ec2-ssh-key.pem
ssh -i ec2-ssh-key.pem ec2-user@$(terraform output -raw ec2_public_ip)

# Stop service
sudo systemctl stop amazon-cloudwatch-agent

# Remove old config
sudo rm -f /opt/aws/amazon-cloudwatch-agent/etc/cloudwatch-config.json

# Recreate config (replace LOG_GROUP with actual value)
LOG_GROUP="/aws/ec2/lab-rds-app"
cat | sudo tee /opt/aws/amazon-cloudwatch-agent/etc/cloudwatch-config.json << EOF
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/notes-app.log",
            "log_group_name": "$LOG_GROUP",
            "log_stream_name": "{instance_id}/app.log",
            "timezone": "UTC"
          }
        ]
      }
    }
  }
}
EOF

# Restart with new config
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/cloudwatch-config.json

# Verify
sudo systemctl status amazon-cloudwatch-agent
```

### Manually Publish Test Metric

```bash
aws cloudwatch put-metric-data \
  --namespace Lab/RDSApp \
  --metric-name DBConnectionErrors \
  --value 1 \
  --timestamp $(date -u +%Y-%m-%dT%H:%M:%S)
```

Check metric appeared:
```bash
aws cloudwatch get-metric-statistics \
  --namespace Lab/RDSApp \
  --metric-name DBConnectionErrors \
  --start-time $(date -u -d '10 minutes ago' --iso-8601=seconds) \
  --end-time $(date -u --iso-8601=seconds) \
  --period 60 \
  --statistics Sum
```

---

## Known Issues & Workarounds

### Issue: CloudWatch Agent Uses Old Config After User-Data Change

**Symptom:** Changed `log_group_name` in Terraform, applied, but agent still uses old log group

**Cause:** EC2 instance not replaced (user-data hash changed but instance not recreated)

**Fix:**
```bash
terraform taint aws_instance.web
terraform apply
```

### Issue: Metric Filter Pattern Not Matching Python Logs

**Symptom:** ERROR logs exist but metric filter doesn't create data points

**Cause:** Python logging format uses ` - ` as delimiter, pattern expects spaces

**Verify pattern:** Manually test the current pattern:

```bash
# Test current pattern with sample log message
aws logs test-metric-filter \
  --filter-pattern '"DB_CONNECTION_FAILURE"' \
  --log-event-messages "2026-01-03 12:00:00 - ERROR - DB_CONNECTION_FAILURE OperationalError: (2003, \"Can't connect\")"
```

**Expected output:** Should show a match.

The pattern in `6-cloudwatch.tf` is:
```hcl
pattern = "\"DB_CONNECTION_FAILURE\""
```

This uses escaped quotes for CloudWatch Logs literal string matching. No changes needed unless the application code changes the token.

---

## Debug Mode

### Enable Flask Debug Logging

**WARNING:** Only for troubleshooting, not production

SSH to EC2:
```bash
# Save key if not already done
terraform output -raw ssh_private_key > ec2-ssh-key.pem
chmod 400 ec2-ssh-key.pem

# Connect
ssh -i ec2-ssh-key.pem ec2-user@$(terraform output -raw ec2_public_ip)

# Edit app to enable debug
sudo sed -i 's/debug=False/debug=True/' /opt/notes-app/app.py

# Restart service
sudo systemctl restart notes-app

# Watch logs
sudo tail -f /var/log/notes-app.log
```

**Remember to disable debug after troubleshooting:**
```bash
sudo sed -i 's/debug=True/debug=False/' /opt/notes-app/app.py
sudo systemctl restart notes-app
```

---

## Prevention

**To avoid credential drift:**
- Never manually change RDS master password in console
- Rotate passwords using Terraform: update secret → `terraform apply`

**To avoid network isolation:**
- Use Terraform for all SG rule changes
- Never manually modify security groups in console
- Monitor SG changes via CloudTrail

**To avoid DB unavailability:**
- Enable RDS automated backups (already disabled for lab cost)
- Use Multi-AZ deployment in production (disabled for lab cost)
- Set up RDS event subscriptions for status changes

---

## When to Escalate

Escalate to senior engineer if:

1. CloudWatch Agent logs show persistent `E!` errors after IAM fix
2. RDS instance status is `failed` or `inaccessible-encryption-credentials`
3. Terraform plan shows unexpected deletions or recreations
4. Multiple components failing simultaneously (possible VPC/networking issue)
5. Metric data delayed > 15 minutes (possible CloudWatch service issue)

---

## Quick Command Reference

```bash
# Get EC2 IP
terraform output -raw ec2_public_ip

# Test app
curl http://$(terraform output -raw ec2_public_ip)/list

# Check alarm
aws cloudwatch describe-alarms --alarm-names lab-db-connection-errors

# View DB connection failure logs
aws logs filter-log-events --log-group-name /aws/ec2/lab-rds-app --filter-pattern DB_CONNECTION_FAILURE

# Get Secrets Manager password
aws secretsmanager get-secret-value --secret-id lab/rds/mysql --query SecretString --output text | jq -r .password

# Check RDS status
aws rds describe-db-instances --db-instance-identifier ec2-rds-notes-lab-mysql --query 'DBInstances[0].DBInstanceStatus'

# Check SG rules
aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$(terraform output -raw rds_security_group_id)"

# SSH to EC2 (save key first - only once)
terraform output -raw ssh_private_key > ec2-ssh-key.pem
chmod 400 ec2-ssh-key.pem
ssh -i ec2-ssh-key.pem ec2-user@$(terraform output -raw ec2_public_ip)
```

---

## Chaos Engineering: Failure Mode Simulations

This section provides controlled procedures to deliberately trigger each of the three common failure modes, allowing you to practice incident response and validate monitoring/alerting systems.

⚠️ **WARNING:** These procedures will cause application downtime and trigger alarms. Only perform in non-production environments. Ensure you have time to complete the recovery process.

---

### Chaos Test 1: Simulate Credential Drift

**Objective:** Trigger database authentication failures by desynchronizing RDS password from Secrets Manager.

**Expected Outcome:**
- CloudWatch alarm `lab-db-connection-errors` transitions to ALARM state
- Application returns 500 errors on database endpoints
- SNS email notification sent (if subscribed and alarm was in OK state)

**Simulation Steps:**

1. **Pre-check: Ensure system is healthy**
   ```bash
   # Verify application working
   curl http://$(terraform output -raw ec2_public_ip)/list

   # Check alarm state (should be OK or INSUFFICIENT_DATA)
   aws cloudwatch describe-alarms \
     --alarm-names lab-db-connection-errors \
     --query 'MetricAlarms[0].StateValue' \
     --output text
   ```
   **Expected:** Application returns `200 OK`, alarm not in ALARM state

2. **Inject failure: Change RDS password without updating Secrets Manager**
   ```bash
   # Generate a new random password different from Secrets Manager
   NEW_PASS="ChaosTesting$(date +%s)!"

   # Change RDS master password
   aws rds modify-db-instance \
     --db-instance-identifier ec2-rds-notes-lab-mysql \
     --master-user-password "$NEW_PASS" \
     --apply-immediately

   # Wait for modification to complete
   echo "Waiting for RDS password change to apply..."
   sleep 120

   aws rds describe-db-instances \
     --db-instance-identifier ec2-rds-notes-lab-mysql \
     --query 'DBInstances[0].DBInstanceStatus' \
     --output text
   ```
   **Expected:** RDS status returns to `available` after ~2 minutes

3. **Trigger application errors**
   ```bash
   # Attempt database operations (will fail with auth error)
   for i in {1..5}; do
     echo "Attempt $i:"
     curl -s http://$(terraform output -raw ec2_public_ip)/list | jq .
     sleep 10
   done
   ```
   **Expected:** All requests return `{"error":"Database connection failed","status":"error"}`

4. **Verify monitoring detected the failure**
   ```bash
   # Check CloudWatch Logs for DB_CONNECTION_FAILURE
   aws logs filter-log-events \
     --log-group-name /aws/ec2/lab-rds-app \
     --filter-pattern "DB_CONNECTION_FAILURE" \
     --start-time $(date -u -d '5 minutes ago' +%s)000 \
     --query 'events[].message' \
     --output text

   # Wait 5-7 minutes for alarm to evaluate
   echo "Waiting for alarm evaluation period..."
   sleep 420

   # Check alarm state
   aws cloudwatch describe-alarms \
     --alarm-names lab-db-connection-errors \
     --query 'MetricAlarms[0].{State:StateValue,Reason:StateReason}' \
     --output table
   ```
   **Expected:**
   - Logs show `Access denied for user 'dbadmin'` errors
   - Alarm transitions to `ALARM` state
   - SNS email received (if subscribed)

5. **Practice incident response: Follow Step 6a (Credential Drift Recovery)**

   **Reference:** [Step 6a: Credential Drift](#scenario-6a-credential-drift) in this runbook

   ```bash
   # Get Secrets Manager password
   SM_PASS=$(aws secretsmanager get-secret-value \
     --secret-id lab/rds/mysql \
     --query SecretString \
     --output text | jq -r .password)

   # Reset RDS password to match Secrets Manager
   aws rds modify-db-instance \
     --db-instance-identifier ec2-rds-notes-lab-mysql \
     --master-user-password "$SM_PASS" \
     --apply-immediately

   # Wait for modification
   sleep 120

   # Test recovery
   curl http://$(terraform output -raw ec2_public_ip)/list
   ```
   **Expected:** Application returns `200 OK` with note list

6. **Verify alarm returns to OK**
   ```bash
   # Wait for alarm evaluation period
   sleep 600

   aws cloudwatch describe-alarms \
     --alarm-names lab-db-connection-errors \
     --query 'MetricAlarms[0].StateValue' \
     --output text
   ```
   **Expected:** Alarm state is `OK`

**Learning Objectives:**
- ✅ Understand how credential drift manifests in logs (`Access denied` errors)
- ✅ Practice using Secrets Manager to retrieve correct passwords
- ✅ Validate CloudWatch metric filter captures authentication errors
- ✅ Confirm alarm threshold and evaluation period settings

---

### Chaos Test 2: Simulate Network Isolation

**Objective:** Trigger connection timeouts by removing security group ingress rule for RDS.

**Expected Outcome:**
- Application cannot connect to RDS (network timeout)
- CloudWatch alarm transitions to ALARM
- Different error signature than credential drift

**Simulation Steps:**

1. **Pre-check: Ensure system is healthy**
   ```bash
   # Verify application working
   curl http://$(terraform output -raw ec2_public_ip)/health

   # Verify SG-to-SG rule exists
   RDS_SG=$(terraform output -raw rds_security_group_id)
   aws ec2 describe-security-group-rules \
     --filters "Name=group-id,Values=$RDS_SG" \
     --query 'SecurityGroupRules[?IsEgress==`false`]' \
     --output table
   ```
   **Expected:** Health check returns `200 OK`, SG rule for port 3306 exists

2. **Inject failure: Remove RDS security group ingress rule**
   ```bash
   # Get RDS security group and rule ID
   RDS_SG=$(terraform output -raw rds_security_group_id)
   RULE_ID=$(aws ec2 describe-security-group-rules \
     --filters "Name=group-id,Values=$RDS_SG" \
     --query 'SecurityGroupRules[?IsEgress==`false`].SecurityGroupRuleId' \
     --output text)

   echo "Removing security group rule: $RULE_ID"

   # Remove the ingress rule
   aws ec2 revoke-security-group-ingress \
     --group-id $RDS_SG \
     --security-group-rule-ids $RULE_ID

   echo "Network isolation injected!"
   ```
   **Expected:** Rule deleted successfully

3. **Trigger application errors**
   ```bash
   # Attempt database operations (will timeout)
   for i in {1..5}; do
     echo "Attempt $i:"
     timeout 15 curl -s http://$(terraform output -raw ec2_public_ip)/list || echo "Request timed out"
     sleep 10
   done
   ```
   **Expected:** Requests timeout or return connection errors

4. **Verify error signature is different from credential drift**
   ```bash
   # Check logs for network timeout errors
   aws logs filter-log-events \
     --log-group-name /aws/ec2/lab-rds-app \
     --filter-pattern "DB_CONNECTION_FAILURE" \
     --start-time $(date -u -d '3 minutes ago' +%s)000 \
     --query 'events[*].message' \
     --output text | head -5
   ```
   **Expected:** Errors show `Can't connect to MySQL server` or `timed out` (NOT `Access denied`)

5. **Practice incident response: Follow Step 6b (Network Isolation Recovery)**

   **Reference:** [Step 6b: Network Isolation](#scenario-6b-network-isolation) in this runbook

   ```bash
   # Recreate the security group rule
   EC2_SG=$(terraform output -raw ec2_security_group_id)
   RDS_SG=$(terraform output -raw rds_security_group_id)

   aws ec2 authorize-security-group-ingress \
     --group-id "$RDS_SG" \
     --ip-permissions IpProtocol=tcp,FromPort=3306,ToPort=3306,UserIdGroupPairs="[{GroupId=$EC2_SG,Description='MySQL from EC2 security group'}]"

   # Verify rule created
   aws ec2 describe-security-group-rules \
     --filters "Name=group-id,Values=$RDS_SG" \
     --query 'SecurityGroupRules[?IsEgress==`false`]' \
     --output table

   # Test immediate recovery (no wait needed for SG changes)
   curl http://$(terraform output -raw ec2_public_ip)/list
   ```
   **Expected:** Application immediately returns `200 OK`

6. **Verify alarm returns to OK**
   ```bash
   # Wait for evaluation period
   sleep 600

   aws cloudwatch describe-alarms \
     --alarm-names lab-db-connection-errors \
     --query 'MetricAlarms[0].StateValue' \
     --output text
   ```
   **Expected:** Alarm state is `OK`

**Learning Objectives:**
- ✅ Understand network isolation vs authentication failure error patterns
- ✅ Practice recreating SG-to-SG reference rules
- ✅ Validate immediate effect of security group changes (no propagation delay)
- ✅ Confirm metric filter captures network errors

---

### Chaos Test 3: Simulate Database Unavailability

**Objective:** Trigger connection failures by stopping the RDS instance.

**Expected Outcome:**
- RDS status changes to `stopped`
- Application cannot connect (database not running)
- CloudWatch alarm transitions to ALARM

**Simulation Steps:**

1. **Pre-check: Ensure system is healthy**
   ```bash
   # Verify RDS available
   aws rds describe-db-instances \
     --db-instance-identifier ec2-rds-notes-lab-mysql \
     --query 'DBInstances[0].DBInstanceStatus' \
     --output text

   # Verify application working
   curl http://$(terraform output -raw ec2_public_ip)/list
   ```
   **Expected:** RDS status is `available`, application returns `200 OK`

2. **Inject failure: Stop RDS instance**
   ```bash
   # Stop the database
   aws rds stop-db-instance \
     --db-instance-identifier ec2-rds-notes-lab-mysql

   echo "Waiting for RDS to stop (this takes 1-3 minutes)..."

   # Monitor stop progress
   while true; do
     STATUS=$(aws rds describe-db-instances \
       --db-instance-identifier ec2-rds-notes-lab-mysql \
       --query 'DBInstances[0].DBInstanceStatus' \
       --output text)
     echo "$(date '+%H:%M:%S') - RDS status: $STATUS"
     [ "$STATUS" = "stopped" ] && break
     sleep 15
   done

   echo "RDS instance stopped!"
   ```
   **Expected:** RDS status transitions through `stopping` → `stopped`

3. **Trigger application errors**
   ```bash
   # Attempt database operations (will fail)
   for i in {1..5}; do
     echo "Attempt $i:"
     curl -s http://$(terraform output -raw ec2_public_ip)/list | jq .
     sleep 10
   done
   ```
   **Expected:** All requests return database connection errors

4. **Verify error signature**
   ```bash
   # Check logs for database unavailable errors
   aws logs filter-log-events \
     --log-group-name /aws/ec2/lab-rds-app \
     --filter-pattern "DB_CONNECTION_FAILURE" \
     --start-time $(date -u -d '3 minutes ago' +%s)000 \
     --query 'events[*].message' \
     --output text | head -3
   ```
   **Expected:** Errors show `Can't connect to MySQL server` with error code 111 or 2003

5. **Practice incident response: Follow Step 6c (Database Unavailability Recovery)**

   **Reference:** [Step 6c: Database Unavailable](#scenario-6c-database-unavailable) in this runbook

   ```bash
   # Start RDS instance
   aws rds start-db-instance \
     --db-instance-identifier ec2-rds-notes-lab-mysql

   echo "Waiting for RDS to start (this takes 3-5 minutes)..."

   # Use AWS waiter
   aws rds wait db-instance-available \
     --db-instance-identifier ec2-rds-notes-lab-mysql

   echo "RDS is available!"

   # Test recovery
   curl http://$(terraform output -raw ec2_public_ip)/list
   ```
   **Expected:** Application returns `200 OK` after RDS starts

6. **Verify alarm returns to OK**
   ```bash
   # Wait for evaluation period
   sleep 600

   aws cloudwatch describe-alarms \
     --alarm-names lab-db-connection-errors \
     --query 'MetricAlarms[0].StateValue' \
     --output text
   ```
   **Expected:** Alarm state is `OK`

**Learning Objectives:**
- ✅ Understand RDS lifecycle (stopping → stopped → starting → available)
- ✅ Practice using AWS waiters for asynchronous operations
- ✅ Validate application resilience during database downtime
- ✅ Confirm RDS stop/start takes 3-5 minutes each direction

---

### Complete Chaos Engineering Run

**For comprehensive testing**, run all three scenarios in sequence:

```bash
#!/bin/bash
# Full Chaos Engineering Test Suite
# WARNING: Causes ~30 minutes of downtime

set -e

EC2_IP=$(terraform output -raw ec2_public_ip)

echo "=== Starting Chaos Engineering Test Suite ==="
echo "Estimated duration: 30-40 minutes"
echo ""

# Test 1: Credential Drift
echo "=== TEST 1: Credential Drift ==="
echo "Injecting credential mismatch..."
NEW_PASS="ChaosTesting$(date +%s)!"
aws rds modify-db-instance \
  --db-instance-identifier ec2-rds-notes-lab-mysql \
  --master-user-password "$NEW_PASS" \
  --apply-immediately
sleep 120

echo "Triggering errors..."
for i in {1..5}; do curl -s http://$EC2_IP/list; sleep 10; done

echo "Recovering..."
SM_PASS=$(aws secretsmanager get-secret-value --secret-id lab/rds/mysql --query SecretString --output text | jq -r .password)
aws rds modify-db-instance \
  --db-instance-identifier ec2-rds-notes-lab-mysql \
  --master-user-password "$SM_PASS" \
  --apply-immediately
sleep 120

curl http://$EC2_IP/list
echo "✓ Test 1 Complete"
echo ""

# Wait for alarm to reset
sleep 360

# Test 2: Network Isolation
echo "=== TEST 2: Network Isolation ==="
echo "Removing security group rule..."
RDS_SG=$(terraform output -raw rds_security_group_id)
RULE_ID=$(aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$RDS_SG" --query 'SecurityGroupRules[?IsEgress==`false`].SecurityGroupRuleId' --output text)
aws ec2 revoke-security-group-ingress --group-id $RDS_SG --security-group-rule-ids $RULE_ID

echo "Triggering errors..."
for i in {1..5}; do timeout 15 curl -s http://$EC2_IP/list || echo "Timeout"; sleep 10; done

echo "Recovering..."
EC2_SG=$(terraform output -raw ec2_security_group_id)
aws ec2 authorize-security-group-ingress \
  --group-id "$RDS_SG" \
  --ip-permissions IpProtocol=tcp,FromPort=3306,ToPort=3306,UserIdGroupPairs="[{GroupId=$EC2_SG,Description='MySQL from EC2 security group'}]"

curl http://$EC2_IP/list
echo "✓ Test 2 Complete"
echo ""

# Wait for alarm to reset
sleep 360

# Test 3: Database Unavailability
echo "=== TEST 3: Database Unavailability ==="
echo "Stopping RDS instance..."
aws rds stop-db-instance --db-instance-identifier ec2-rds-notes-lab-mysql
echo "Waiting for RDS to stop..."
aws rds wait db-instance-stopped --db-instance-identifier ec2-rds-notes-lab-mysql

echo "Triggering errors..."
for i in {1..5}; do curl -s http://$EC2_IP/list; sleep 10; done

echo "Recovering..."
aws rds start-db-instance --db-instance-identifier ec2-rds-notes-lab-mysql
echo "Waiting for RDS to start..."
aws rds wait db-instance-available --db-instance-identifier ec2-rds-notes-lab-mysql

curl http://$EC2_IP/list
echo "✓ Test 3 Complete"
echo ""

echo "=== Chaos Engineering Test Suite Complete ==="
echo "All 3 failure modes tested successfully!"
```

**Save as:** `chaos-test-suite.sh`

**Run:** `bash chaos-test-suite.sh`

---

### Chaos Engineering Best Practices

**Before running chaos tests:**
1. ✅ Ensure you have 45-60 minutes for complete test cycle
2. ✅ Verify SNS email subscription confirmed (to test alerting)
3. ✅ Document baseline state (alarm status, application response times)
4. ✅ Have this runbook open for quick reference during recovery
5. ✅ Run during low-usage periods (or in dedicated test environment)

**During chaos tests:**
1. 📝 Document time to detection (how long until alarm triggers)
2. 📝 Document time to recovery (how long to restore service)
3. 📝 Note any unexpected behaviors or error messages
4. 📝 Verify SNS emails arrive and contain useful information

**After chaos tests:**
1. 📊 Review CloudWatch Logs to confirm all errors captured
2. 📊 Check alarm history for state transitions
3. 📊 Validate metric filter generated correct data points
4. 📊 Compare actual vs expected behaviors
5. 📋 Update runbook if recovery steps need refinement

**Testing frequency recommendations:**
- Run full suite: **Monthly** (or before major changes)
- Run single scenario: **Weekly** (rotate between the three)
- Validate monitoring only: **Daily** (check alarm status, review logs)

---

## Additional Resources

- [CloudWatch Agent Troubleshooting](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/troubleshooting-CloudWatch-Agent.html)
- [CloudWatch Logs Insights Query Examples](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/CWL_QuerySyntax-examples.html)
- [Metric Filter Pattern Syntax](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/FilterAndPatternSyntax.html)
- Lab 1a RUNBOOK.md for network/RDS issues
