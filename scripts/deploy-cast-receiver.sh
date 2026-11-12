#!/bin/bash
# Upload the Cast receiver page (cast-receiver/) to the web server that hosts it.
# The receiver URL registered in the Google Cast SDK Developer Console points there.
#
#   CAST_DEPLOY_TARGET="host:/path/to/cast/aiusage" scripts/deploy-cast-receiver.sh
set -euo pipefail
: "${CAST_DEPLOY_TARGET:?set CAST_DEPLOY_TARGET to host:/path of the receiver folder}"
cd "$(dirname "$0")/.."
host="${CAST_DEPLOY_TARGET%%:*}"; path="${CAST_DEPLOY_TARGET#*:}"
ssh "$host" "mkdir -p '$path'"
rsync -rlt --delete --exclude ".*" --chmod=Dg+s,Dug=rwx,Do=rx,Fug=rw,Fo=r cast-receiver/ "$CAST_DEPLOY_TARGET/"
echo "Uploaded to $CAST_DEPLOY_TARGET"
