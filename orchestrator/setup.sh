#!/bin/bash
# setup.sh — Create and publish the SELinux Orchestrator workflow.
# Idempotent: safe to re-run.
#
# Prerequisites:
#   - AAP Controller provisioned via controller/setup.yml (job templates exist)
#   - Orchestrator deployed and accessible
#
# Usage:
#   AAP_PASS=<password> bash orchestrator/setup.sh
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
ORCHESTRATOR_URL="${ORCHESTRATOR_URL:-https://automa-d61a1901-automation-orchestrator-automation-orchestrator.apps.sno.stoleas.home}"
AAP_URL="${AAP_URL:-https://aap-aap.apps.sno.stoleas.home}"
ORCHESTRATOR_USER="${ORCHESTRATOR_USER:-admin}"
ORCHESTRATOR_PASS="${ORCHESTRATOR_PASS:-password}"
AAP_USER="${AAP_USER:-admin}"
AAP_PASS="${AAP_PASS:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Helpers ──────────────────────────────────────────────────────────────────
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
blue()  { printf '\033[34m%s\033[0m\n' "$*"; }
die()   { red "ERROR: $*"; exit 1; }
step()  { echo; blue "── $* ──"; }
ok()    { green "  ✓ $*"; }

curl_json() { curl -skL -H "Content-Type: application/json" "$@"; }

if [[ -z "$AAP_PASS" ]]; then
  read -rsp "AAP admin password: " AAP_PASS && echo
fi

# ── Orchestrator auth ────────────────────────────────────────────────────────
step "Authenticating with Automation Orchestrator"
TOKEN=$(curl_json -X POST "$ORCHESTRATOR_URL/api/v1/auth/login" \
  -d "{\"username\":\"$ORCHESTRATOR_USER\",\"password\":\"$ORCHESTRATOR_PASS\"}" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null)
[[ -z "$TOKEN" ]] && die "Orchestrator login failed — check ORCHESTRATOR_USER / ORCHESTRATOR_PASS"
ok "Authenticated as $ORCHESTRATOR_USER"

orch() { curl_json -H "Authorization: Bearer $TOKEN" "$@"; }
aap()  { curl_json -u "$AAP_USER:$AAP_PASS" "$@"; }

orch_id_by_name() {
  local path="$1" name="$2"
  orch "$ORCHESTRATOR_URL$path" | \
    python3 -c "import sys,json; items=json.load(sys.stdin).get('resources',[]); ids=[i['id'] for i in items if i['name']=='$name']; print(ids[0] if ids else '')" 2>/dev/null
}
aap_id_by_name() {
  local path="$1" name="$2"
  aap "$AAP_URL$path?name=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$name'))")" | \
    python3 -c "import sys,json; results=json.load(sys.stdin).get('results',[]); print(results[0]['id'] if results else '')" 2>/dev/null
}

# ── Part 1: AAP Gateway integration ─────────────────────────────────────────
step "AAP Gateway integration"
AAP_INT_ID=$(orch_id_by_name /api/v1/integrations "AAP Gateway")
if [[ -n "$AAP_INT_ID" ]]; then
  ok "Already exists — $AAP_INT_ID"
else
  RESP=$(orch -X POST "$ORCHESTRATOR_URL/api/v1/integrations" -d "{
    \"name\": \"AAP Gateway\",
    \"integration_type\": \"aap_gateway\",
    \"scope\": \"global\",
    \"enabled\": true,
    \"configuration\": {\"integration_type\": \"aap_gateway\", \"gateway_url\": \"$AAP_URL\", \"insecure_skip_tls_verify\": true}
  }")
  AAP_INT_ID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
  [[ -z "$AAP_INT_ID" ]] && die "AAP integration create failed: $RESP"
  ok "Created — $AAP_INT_ID"
fi
orch -X POST "$ORCHESTRATOR_URL/api/v1/integrations/$AAP_INT_ID/validate" >/dev/null 2>&1 && ok "AAP Gateway validated" || red "  WARNING: AAP Gateway validation failed"

# ── Part 2: Look up AAP credential in Orchestrator ──────────────────────────
step "AAP credential in Orchestrator"
AAP_CRED_ID=$(orch "$ORCHESTRATOR_URL/api/v1/credentials" | \
  python3 -c "
import sys, json
creds = json.load(sys.stdin).get('resources', [])
aap = [c['id'] for c in creds if 'aap' in c.get('name','').lower() or 'gateway' in c.get('name','').lower()]
print(aap[0] if aap else '')
" 2>/dev/null)

if [[ -z "$AAP_CRED_ID" ]]; then
  blue "  No AAP credential found — creating one"
  AAP_CRED_TYPE_ID=$(orch "$ORCHESTRATOR_URL/api/v1/credential-types" | \
    python3 -c "import sys,json; types=json.load(sys.stdin).get('resources',[]); ids=[t['id'] for t in types if 'aap' in t.get('name','').lower()]; print(ids[0] if ids else '')" 2>/dev/null)
  [[ -z "$AAP_CRED_TYPE_ID" ]] && die "Cannot find AAP credential type in Orchestrator"
  RESP=$(orch -X POST "$ORCHESTRATOR_URL/api/v1/credentials" -d "{
    \"name\": \"AAP Gateway Credential\",
    \"credential_type_id\": \"$AAP_CRED_TYPE_ID\",
    \"inputs\": {\"host\": \"$AAP_URL\", \"username\": \"$AAP_USER\", \"password\": \"$AAP_PASS\"}
  }")
  AAP_CRED_ID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
  [[ -z "$AAP_CRED_ID" ]] && die "AAP credential create failed: $RESP"
  ok "Created — $AAP_CRED_ID"
else
  ok "Found — $AAP_CRED_ID"
fi

# ── Part 3: Look up AAP job template IDs ─────────────────────────────────────
step "Discovering AAP job template IDs"
AI_JT_ID=$(aap_id_by_name /api/controller/v2/job_templates "SELinux - AI Analysis")
[[ -z "$AI_JT_ID" ]] && die "Job template 'SELinux - AI Analysis' not found — run controller/setup.yml first"
ok "AI Analysis JT: $AI_JT_ID"

REPORT_JT_ID=$(aap_id_by_name /api/controller/v2/job_templates "SELinux - Generate Report")
[[ -z "$REPORT_JT_ID" ]] && die "Job template 'SELinux - Generate Report' not found"
ok "Generate Report JT: $REPORT_JT_ID"

REMEDIATE_JT_ID=$(aap_id_by_name /api/controller/v2/job_templates "SELinux - Apply Remediation")
[[ -z "$REMEDIATE_JT_ID" ]] && die "Job template 'SELinux - Apply Remediation' not found"
ok "Apply Remediation JT: $REMEDIATE_JT_ID"

# ── Part 4: Create and publish workflow ──────────────────────────────────────
step "Creating Orchestrator workflow"
WF_ID=$(orch_id_by_name /api/v1/workflows "SELinux Remediation Workflow")
if [[ -n "$WF_ID" ]]; then
  ok "Workflow already exists — $WF_ID"
else
  WFDEF=$(python3 -c "
import json
with open('$SCRIPT_DIR/workflow-definition.json') as f:
    d = json.load(f)
for node in d['workflow_definition']['nodes']:
    cfg = node['config']
    if 'credential_id' in cfg:
        cfg['credential_id'] = '$AAP_CRED_ID'
    if 'job_template_id' in cfg:
        name = node['name']
        if 'Analysis' in name:
            cfg['job_template_id'] = $AI_JT_ID
        elif 'Report' in name:
            cfg['job_template_id'] = $REPORT_JT_ID
        elif 'Remediation' in name:
            cfg['job_template_id'] = $REMEDIATE_JT_ID
print(json.dumps(d))
")
  RESP=$(orch -X POST "$ORCHESTRATOR_URL/api/v1/workflows" -d "$WFDEF")
  WF_ID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
  [[ -z "$WF_ID" ]] && die "Workflow create failed: $RESP"
  ok "Workflow created — $WF_ID"
fi

step "Publishing workflow"
PUB=$(orch -X POST "$ORCHESTRATOR_URL/api/v1/workflows/$WF_ID/versions/1/publish" \
  -d '{}' 2>/dev/null || echo '{}')
PUB_VER=$(echo "$PUB" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('published_version') or d.get('version',{}).get('status','(unknown)'))" 2>/dev/null)
ok "Published — version: $PUB_VER"

# ── Summary ──────────────────────────────────────────────────────────────────
echo
green "═══════════════════════════════════════════════"
green "  SELinux Orchestrator workflow ready!"
green "═══════════════════════════════════════════════"
echo "  Workflow ID:           $WF_ID"
echo "  Webhook path:          selinux"
echo "  AI Analysis JT:        $AI_JT_ID"
echo "  Generate Report JT:    $REPORT_JT_ID"
echo "  Apply Remediation JT:  $REMEDIATE_JT_ID"
echo "  AAP Credential:        $AAP_CRED_ID"
echo
echo "Trigger via EDA event stream:"
echo "  curl -k -u selinux:redhat123 -X POST \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"action\": \"selinux_analysis\", \"host\": \"selinux-demo\"}' \\"
echo "    'https://aap-aap.apps.sno.stoleas.home/eda-event-streams/api/eda/v1/external_event_stream/b86e11ce-d4e0-45bb-a867-9ab79f7c32ad/post/'"
echo
echo "Check pending approvals:"
echo "  curl -sk -H 'Authorization: Bearer $TOKEN' \\"
echo "    '$ORCHESTRATOR_URL/api/v1/approvals?status=pending'"
echo
echo "Approve:"
echo "  curl -sk -X PATCH -H 'Authorization: Bearer $TOKEN' \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"status\":\"approved\"}' \\"
echo "    '$ORCHESTRATOR_URL/api/v1/approvals/<id>'"
