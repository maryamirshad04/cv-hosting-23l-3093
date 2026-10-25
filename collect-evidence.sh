#!/bin/bash
# Collects the evidence for the CV hosting assignment into evidence.txt.
#
# Usage: ./collect-evidence.sh <bucket-name> <ec2-address> <lambda-address>
#   example: ./collect-evidence.sh cv-23l-3093 http://3.12.34.56 https://abc123.lambda-url.us-east-1.on.aws/
#
# Run it where the AWS CLI is logged in to your account (for example AWS CloudShell).
# If a command fails, the section says so and the script carries on.
# Names below follow the assignment (roll number in lower case). Override with
# environment variables if yours are different, for example: ROLL=23l-3093 ./collect-evidence.sh ...

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <bucket-name> <ec2-address> <lambda-address>"
    exit 1
fi

BUCKET="$1"
EC2_ADDR="$2"
LAMBDA_ADDR="$3"

ROLL="${ROLL:-23l-3093}"
INSTANCE_NAME="${INSTANCE_NAME:-cv-ec2-$ROLL}"
EC2_ROLE="${EC2_ROLE:-cv-ec2-role-$ROLL}"
LAMBDA_ROLE="${LAMBDA_ROLE:-cv-lambda-role-$ROLL}"
FUNCTION="${FUNCTION:-cv-func-$ROLL}"
OUT="evidence.txt"

# Accept addresses with or without http(s):// and with or without a trailing slash.
case "$EC2_ADDR" in http://*|https://*) ;; *) EC2_ADDR="http://$EC2_ADDR" ;; esac
case "$LAMBDA_ADDR" in http://*|https://*) ;; *) LAMBDA_ADDR="https://$LAMBDA_ADDR" ;; esac
EC2_ADDR="${EC2_ADDR%/}"
LAMBDA_ADDR="${LAMBDA_ADDR%/}"

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null)}}"
S3_DIRECT="https://${BUCKET}.s3.${REGION:-us-east-1}.amazonaws.com/site/index.html"

# section <name> <command...>: prints the header, runs the command, notes a failure.
section() {
    local name="$1"; shift
    echo "== $name =="
    if ! "$@" 2>&1; then
        echo "(command failed: $*)"
    fi
    echo
}

# --- helpers for the sections that need more than one command -----------------------------
role_policies() {   # role_policies <role>: attached (managed) policies and inline policies
    local role="$1" p
    echo "-- attached managed policies"
    aws iam list-attached-role-policies --role-name "$role" --output json || return 1
    echo "-- inline policies"
    for p in $(aws iam list-role-policies --role-name "$role" --query 'PolicyNames[]' --output text); do
        echo "inline policy: $p"
        aws iam get-role-policy --role-name "$role" --policy-name "$p" --output json || return 1
    done
}

instance_ids() {
    aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=pending,running" \
        --query 'Reservations[].Instances[].InstanceId' --output text
}

security_group() {
    local id sg
    id=$(instance_ids | awk '{print $1}')
    [ -n "$id" ] || { echo "no running instance named $INSTANCE_NAME"; return 1; }
    sg=$(aws ec2 describe-instances --instance-ids "$id" \
         --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' --output text) || return 1
    # shellcheck disable=SC2086
    aws ec2 describe-security-groups --group-ids $sg \
        --query 'SecurityGroups[].{Name:GroupName,Id:GroupId,Inbound:IpPermissions}' --output json
}

instance_details() {
    local id
    id=$(instance_ids | awk '{print $1}')
    [ -n "$id" ] || { echo "no running instance named $INSTANCE_NAME"; return 1; }
    aws ec2 describe-instances --instance-ids "$id" --query \
        'Reservations[0].Instances[0].{InstanceId:InstanceId,Type:InstanceType,State:State.Name,PublicIp:PublicIpAddress,HttpTokens:MetadataOptions.HttpTokens,HttpEndpoint:MetadataOptions.HttpEndpoint,InstanceProfile:IamInstanceProfile.Arn,Tags:Tags}' \
        --output json
}

endpoints() {
    local u
    for u in "$EC2_ADDR/" "$EC2_ADDR/style.css" "$EC2_ADDR/cv.pdf" \
             "$LAMBDA_ADDR/" "$LAMBDA_ADDR/style.css" "$LAMBDA_ADDR/cv.pdf" "$LAMBDA_ADDR/anything" \
             "$S3_DIRECT"; do
        printf '%s  ' "$u"
        curl -s -o /dev/null --max-time 20 -w 'status=%{http_code} content-type=%{content_type}\n' "$u" \
            || echo "status=000 (request failed)"
    done
}

# --- the 11 sections -------------------------------------------------------------------------
{
    echo "Evidence for bucket=$BUCKET ec2=$EC2_ADDR lambda=$LAMBDA_ADDR"
    echo "Collected at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo

    section caller          aws sts get-caller-identity --output json
    section public-access   aws s3api get-public-access-block --bucket "$BUCKET" --output json
    section versioning      aws s3api get-bucket-versioning --bucket "$BUCKET" --output json
    section objects         aws s3 ls "s3://$BUCKET/site/" --recursive
    section ec2-policy      role_policies "$EC2_ROLE"
    section lambda-policy   role_policies "$LAMBDA_ROLE"
    section security-group  security_group
    section instance        instance_details
    section endpoints       endpoints
    section lambda-logs     bash -c "set -o pipefail; aws logs tail '/aws/lambda/$FUNCTION' --since 1h | tail -n 10"
    section log-retention   aws logs describe-log-groups --log-group-name-prefix "/aws/lambda/$FUNCTION" \
                                --query 'logGroups[].{LogGroup:logGroupName,RetentionInDays:retentionInDays}' --output json
} > "$OUT"

echo "DONE"
