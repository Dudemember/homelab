#!/usr/bin/env bash
set -euo pipefail

# run_on_nodes.sh — SSH to each node in localvars and run the given command
LOCALVARS=./localvars
[[ -r $LOCALVARS ]] || { echo "ERROR: cannot read $LOCALVARS" >&2; exit 1; }
source "$LOCALVARS"

: "${USER:?USER must be set in localvars}"
: "${MY_SSH_KEY:?MY_SSH_KEY must be set in localvars}"
[[ "${#NODES[@]}" -gt 0 ]] || { echo "ERROR: NODES array must be defined in localvars" >&2; exit 1; }

SSH_KEY="${MY_SSH_KEY/#\~/$HOME}"
SSH_OPTS="-i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=5 \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <command-to-run>"
  exit 1
fi

echo "→ Running on nodes: ${NODES[*]}"
for host in "${NODES[@]}"; do
  echo
  echo "----- $host -----"
  ssh $SSH_OPTS "${USER}@${host}" "$*"
done
