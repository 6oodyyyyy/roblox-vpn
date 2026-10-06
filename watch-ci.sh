#!/bin/bash
# Watches the 6oodyyyyy/roblox-vpn CI build for the latest push, then
# downloads the windows-exe artifact into ~/workspace/roblox-vpn/dist/.
# Never prints the token.
set -u
REPO="6oodyyyyy/roblox-vpn"
OUTDIR="$HOME/workspace/roblox-vpn/dist"
TOK=$(cat "$HOME/.config/gh_toto_token")
AUTH="Authorization: Basic $(printf '6oodyyyyy:%s' "$TOK" | base64 -w0)"
unset TOK
api() { curl -s -H "$AUTH" "https://api.github.com/repos/$REPO/$1"; }

RUN_ID=""
for i in $(seq 1 40); do
  INFO=$(api "actions/runs?per_page=5" | python3 -c "
import json,sys
d = json.load(sys.stdin)
runs = [r for r in d.get('workflow_runs', []) if r.get('head_branch') == 'main']
r = runs[0] if runs else None
print((r['status'] + ' ' + str(r['conclusion']) + ' ' + str(r['id'])) if r else 'NONE')
")
  echo "poll $i: $INFO"
  set -- $INFO
  if [ "$1" = "completed" ]; then RUN_ID=$3; CONCLUSION=$2; break; fi
  sleep 30
done
if [ -z "$RUN_ID" ]; then echo "TIMEOUT waiting for CI"; exit 1; fi
echo "run $RUN_ID conclusion: $CONCLUSION"
if [ "$CONCLUSION" != "success" ]; then
  echo "CI did not succeed: $CONCLUSION"
  api "actions/runs/$RUN_ID/jobs?per_page=5" | python3 -c "
import json,sys
d = json.load(sys.stdin)
for j in d.get('jobs', []):
    print(j['name'], '->', j['conclusion'])
"
  exit 2
fi
AID=$(api "actions/runs/$RUN_ID/artifacts?per_page=10" | python3 -c "
import json,sys
d = json.load(sys.stdin)
a = [x for x in d.get('artifacts', []) if x['name'] == 'windows-exe']
print(a[0]['id'] if a else 'NONE')
")
if [ "$AID" = "NONE" ]; then echo "artifact not found"; exit 3; fi
mkdir -p "$OUTDIR"
curl -sL -H "$AUTH" -o /tmp/robloxvnp-exe.zip \
  "https://api.github.com/repos/$REPO/actions/artifacts/$AID/zip"
unzip -o /tmp/robloxvnp-exe.zip -d "$OUTDIR" >/dev/null
rm -f /tmp/robloxvnp-exe.zip
ls -la "$OUTDIR/RobloxVPN.exe"
# Optional $1 = version suffix (e.g. v11): keep a versioned copy so downloads
# never serve a stale cached file under the same name.
if [ -n "${1:-}" ]; then
  cp "$OUTDIR/RobloxVPN.exe" "$OUTDIR/RobloxVPN-$1.exe"
  ls -la "$OUTDIR/RobloxVPN-$1.exe"
fi
echo "DONE: new exe in $OUTDIR"
