#!/bin/bash
# Copies the site/ prefix of the private S3 bucket to the web root, then puts
# "EC2 <instance id>" in place of the {{HOSTED_ON}} placeholder.
# It uses the instance role (no access keys). It is run once by user-data.sh and then
# every 2 minutes by the systemd timer cv-sync.timer.
# Settings are read from /etc/cv-sync.env: BUCKET and PREFIX.
set -u

LOG=/var/log/cv-sync.log
STAGE=/var/lib/cv-site
WEBROOT=/usr/share/nginx/html

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $1" >> "$LOG"; }

# shellcheck disable=SC1091
source /etc/cv-sync.env

# IMDSv2: get a token first, then use it for every metadata request.
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
meta() { curl -s -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/$1"; }
INSTANCE_ID=$(meta instance-id)
REGION=$(meta placement/region)

mkdir -p "$STAGE"

if ! aws s3 sync "s3://${BUCKET}/${PREFIX}" "$STAGE" --delete --region "$REGION" --only-show-errors; then
    log "sync FAILED (s3 sync error)"
    exit 1
fi

if [ ! -s "$STAGE/index.html" ] || [ -z "$INSTANCE_ID" ]; then
    log "sync FAILED (index.html missing or no instance id)"
    exit 1
fi

# Copy to the web root. index.html is written to a temp file first and then renamed,
# so a visitor never sees a half-written page.
for f in style.css cv.pdf; do
    [ -f "$STAGE/$f" ] && install -m 644 "$STAGE/$f" "$WEBROOT/$f"
done
sed "s/{{HOSTED_ON}}/EC2 ${INSTANCE_ID}/g" "$STAGE/index.html" > "$WEBROOT/.index.html.tmp"
chmod 644 "$WEBROOT/.index.html.tmp"
mv -f "$WEBROOT/.index.html.tmp" "$WEBROOT/index.html"

log "sync OK (instance ${INSTANCE_ID})"
