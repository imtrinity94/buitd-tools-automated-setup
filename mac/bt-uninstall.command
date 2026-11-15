#!/bin/bash
# Double-click: removes the Build Tools setup. Shows the plan and asks before
# deleting anything; logs to bt-uninstall.log. Your projects are never touched.
cd "$(dirname "$0")" || exit 1
{ echo "START $(date)"; bash ./bt-setup.sh uninstall; echo "EXIT=$?"; } 2>&1 | tee bt-uninstall.log
echo; echo "Finished - you can close this window."
