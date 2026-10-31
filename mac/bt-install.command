#!/bin/bash
# Double-click launcher: runs bt-setup.sh install and logs to bt-setup.log
cd "$(dirname "$0")" || exit 1
export BT_GEN_KEYPASS=1 BT_SKIP_PROFILE=1
{ echo "START $(date)"; bash ./bt-setup.sh install; echo "EXIT=$?"; } 2>&1 | tee bt-setup.log
echo; echo "Finished - you can close this window."
