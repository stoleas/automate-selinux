#!/bin/bash
# setup.sh — Create and publish the SELinux Orchestrator workflow (AO 2026.8).
# Idempotent: safe to re-run.
#
# DAG: EDA → AI triage → python normalize → switch
#   auto_patch_dev: commit → sync → dynamic apply JT → observe
#   approval_required_prod: AO approval → same chain
#   investigate: second agent → parse → notify JT
#   fallback: python no-op
#
# Prerequisites:
#   - AAP Controller provisioned via controller/setup.yml (job templates exist)
#   - Orchestrator deployed and accessible
#   - LLM proxy reachable from Orchestrator pods (default: Vertex proxy)
#
# Usage:
#   AAP_PASS=<password> ORCHESTRATOR_PASS=<password> bash orchestrator/setup.sh
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
ORCHESTRATOR_URL="${ORCHESTRATOR_URL:-https://orchestrator.apps.sno.stoleas.home}"
ORCHESTRATOR_RESOLVE_IP="${ORCHESTRATOR_RESOLVE_IP:-192.168.86.145}"
AAP_URL="${AAP_URL:-https://aap-aap.apps.sno.stoleas.home}"
AAP_RESOLVE_IP="${AAP_RESOLVE_IP:-192.168.86.145}"
# Orchestrator pods cannot resolve *.apps.sno.stoleas.home (CoreDNS NXDOMAIN)
# and langchain SSRF blocks *.svc.cluster.local. Short in-cluster name works.
AAP_INTEGRATION_URL="${AAP_INTEGRATION_URL:-http://aap.aap.svc}"
ORCHESTRATOR_USER="${ORCHESTRATOR_USER:-admin}"
ORCHESTRATOR_PASS="${ORCHESTRATOR_PASS:-}"
AAP_USER="${AAP_USER:-admin}"
AAP_PASS="${AAP_PASS:-}"
LLM_BASE_URL="${LLM_BASE_URL:-http://192.168.86.11:8787}"
LLM_MODEL_NAME="${LLM_MODEL_NAME:-claude-haiku-4-5}"
LLM_API_KEY="${LLM_API_KEY:-dummy}"
WF_NAME="SELinux Remediation Workflow"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
blue()  { printf '\033[34m%s\033[0m\n' "$*"; }
die()   { red "ERROR: $*"; exit 1; }
step()  { echo; blue "── $* ──"; }
ok()    { green "  ✓ $*"; }

ORCH_HOST="$(python3 -c "from urllib.parse import urlparse; print(urlparse('$ORCHESTRATOR_URL').hostname or '')")"
AAP_HOST="$(python3 -c "from urllib.parse import urlparse; print(urlparse('$AAP_URL').hostname or '')")"

curl_json() {
  local extra=()
  extra+=(-skL -H "Content-Type: application/json")
  if [[ -n "$ORCHESTRATOR_RESOLVE_IP" && -n "$ORCH_HOST" ]]; then
    extra+=(--resolve "${ORCH_HOST}:443:${ORCHESTRATOR_RESOLVE_IP}")
  fi
  curl "${extra[@]}" "$@"
}

curl_aap() {
  local extra=()
  extra+=(-skL -H "Content-Type: application/json")
  if [[ -n "$AAP_RESOLVE_IP" && -n "$AAP_HOST" ]]; then
    extra+=(--resolve "${AAP_HOST}:443:${AAP_RESOLVE_IP}")
  fi
  curl "${extra[@]}" "$@"
}

if [[ -z "$AAP_PASS" ]]; then
  read -rsp "AAP admin password: " AAP_PASS && echo
fi
if [[ -z "$ORCHESTRATOR_PASS" ]]; then
  read -rsp "Orchestrator admin password: " ORCHESTRATOR_PASS && echo
fi
export AAP_PASS ORCHESTRATOR_PASS LLM_API_KEY LLM_MODEL_NAME AAP_USER ORCHESTRATOR_USER

# ── Orchestrator auth ────────────────────────────────────────────────────────
step "Authenticating with Automation Orchestrator"
TOKEN=$(curl_json -X POST "$ORCHESTRATOR_URL/api/v1/auth/login" \
  -d "{\"username\":\"$ORCHESTRATOR_USER\",\"password\":\"$ORCHESTRATOR_PASS\"}" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null)
[[ -z "$TOKEN" ]] && die "Orchestrator login failed — check ORCHESTRATOR_USER / ORCHESTRATOR_PASS"
ok "Authenticated as $ORCHESTRATOR_USER"

orch() { curl_json -H "Authorization: Bearer $TOKEN" "$@"; }
aap()  { curl_aap -u "$AAP_USER:$AAP_PASS" "$@"; }

orch_id_by_name() {
  local path="$1" name="$2"
  orch "$ORCHESTRATOR_URL$path" | \
    python3 -c "import sys,json; items=json.load(sys.stdin).get('resources',[]); ids=[i['id'] for i in items if i.get('name')=='$name']; print(ids[0] if ids else '')" 2>/dev/null
}

aap_id_by_name() {
  local path="$1" name="$2"
  aap "$AAP_URL$path?name=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$name'))")" | \
    python3 -c "import sys,json; results=json.load(sys.stdin).get('results',[]); print(results[0]['id'] if results else '')" 2>/dev/null
}

# ── Default project (required on 2026.8 creates) ─────────────────────────────
step "Default Orchestrator project"
PROJECT_ID=$(orch "$ORCHESTRATOR_URL/api/v1/projects" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('resources', [])
default = [i['id'] for i in items if i.get('is_default')]
builtin_skip = [i['id'] for i in items if i.get('name')=='default']
print((default or builtin_skip or [items[0]['id']])[0] if items else '')
")
[[ -z "$PROJECT_ID" ]] && die "No Orchestrator project found"
ok "Project $PROJECT_ID"

# ── Part 1: AAP credential (required before AAP integration on 2026.8) ───────
step "AAP credential in Orchestrator"
AAP_CRED_ID=$(orch "$ORCHESTRATOR_URL/api/v1/credentials" | python3 -c "
import sys, json
creds = json.load(sys.stdin).get('resources', [])
aap = [c['id'] for c in creds if 'aap' in c.get('name','').lower() or 'gateway' in c.get('name','').lower()]
print(aap[0] if aap else '')
")
if [[ -z "$AAP_CRED_ID" ]]; then
  AAP_CRED_TYPE_ID=$(orch "$ORCHESTRATOR_URL/api/v1/credential_types" | python3 -c "
import sys, json
types = json.load(sys.stdin).get('resources', [])
ids = [t['id'] for t in types if 'ansible automation platform' in t.get('name','').lower() or t.get('name','').lower()=='aap']
print(ids[0] if ids else '')
")
  [[ -z "$AAP_CRED_TYPE_ID" ]] && die "Cannot find AAP credential type in Orchestrator"
  RESP=$(orch -X POST "$ORCHESTRATOR_URL/api/v1/credentials" -d "{
    \"name\": \"AAP Gateway Credential\",
    \"credential_type_id\": \"$AAP_CRED_TYPE_ID\",
    \"project_id\": \"$PROJECT_ID\",
    \"inputs\": {\"username\": \"$AAP_USER\", \"password\": $(python3 -c "import json,os; print(json.dumps(os.environ.get('AAP_PASS','')))")}
  }")
  AAP_CRED_ID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
  [[ -z "$AAP_CRED_ID" ]] && die "AAP credential create failed: $RESP"
  ok "Created — $AAP_CRED_ID"
else
  ok "Found — $AAP_CRED_ID"
fi

# ── Part 2: AAP integration ──────────────────────────────────────────────────
step "AAP Gateway integration"
AAP_INT_ID=$(orch "$ORCHESTRATOR_URL/api/v1/integrations" | python3 -c "
import sys, json
ints = json.load(sys.stdin).get('resources', [])
ids = [i['id'] for i in ints if i.get('integration_type') in ('ansible_automation_platform','aap_gateway') or i.get('name')=='AAP Gateway']
print(ids[0] if ids else '')
")
if [[ -n "$AAP_INT_ID" ]]; then
  ok "Already exists — $AAP_INT_ID"
else
  RESP=$(orch -X POST "$ORCHESTRATOR_URL/api/v1/integrations" -d "{
    \"name\": \"AAP Gateway\",
    \"integration_type\": \"ansible_automation_platform\",
    \"scope\": \"global\",
    \"enabled\": true,
    \"management_credential_id\": \"$AAP_CRED_ID\",
    \"configuration\": {
      \"integration_type\": \"ansible_automation_platform\",
      \"base_url\": \"$AAP_INTEGRATION_URL\",
      \"allow_http\": true,
      \"insecure_skip_tls_verify\": true
    }
  }")
  AAP_INT_ID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
  [[ -z "$AAP_INT_ID" ]] && die "AAP integration create failed: $RESP"
  ok "Created — $AAP_INT_ID"
fi
# Keep the in-cluster AAP URL even when the integration already exists.
orch -X PATCH "$ORCHESTRATOR_URL/api/v1/integrations/$AAP_INT_ID" -d "{
  \"configuration\": {
    \"integration_type\": \"ansible_automation_platform\",
    \"base_url\": \"$AAP_INTEGRATION_URL\",
    \"allow_http\": true,
    \"insecure_skip_tls_verify\": true
  }
}" >/dev/null
ok "AAP integration URL $AAP_INTEGRATION_URL"
orch -X POST "$ORCHESTRATOR_URL/api/v1/integrations/$AAP_INT_ID/validate" >/dev/null 2>&1 && ok "AAP Gateway validated" || red "  WARNING: AAP Gateway validation failed"

# ── Part 3: LLM credential + integration ─────────────────────────────────────
step "LLM credential"
LLM_CRED_TYPE_ID=$(orch "$ORCHESTRATOR_URL/api/v1/credential_types" | python3 -c "
import sys, json
types = json.load(sys.stdin).get('resources', [])
ids = [t['id'] for t in types if t.get('name')=='LLM Provider']
print(ids[0] if ids else '')
")
[[ -z "$LLM_CRED_TYPE_ID" ]] && die "Cannot find LLM Provider credential type"

LLM_CRED_ID=$(orch "$ORCHESTRATOR_URL/api/v1/credentials" | python3 -c "
import sys, json
creds = json.load(sys.stdin).get('resources', [])
ids = [c['id'] for c in creds if c.get('name') in ('Vertex AI Proxy','LLM Provider Credential') or 'llm' in c.get('name','').lower() or 'vertex' in c.get('name','').lower()]
print(ids[0] if ids else '')
")
if [[ -z "$LLM_CRED_ID" ]]; then
  RESP=$(orch -X POST "$ORCHESTRATOR_URL/api/v1/credentials" -d "{
    \"name\": \"Vertex AI Proxy\",
    \"credential_type_id\": \"$LLM_CRED_TYPE_ID\",
    \"project_id\": \"$PROJECT_ID\",
    \"inputs\": {\"api_key\": $(python3 -c "import json,os; print(json.dumps(os.environ.get('LLM_API_KEY','dummy')))")}
  }")
  LLM_CRED_ID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
  [[ -z "$LLM_CRED_ID" ]] && die "LLM credential create failed: $RESP"
  ok "Created — $LLM_CRED_ID"
else
  ok "Found — $LLM_CRED_ID"
fi

step "LLM integration"
LLM_INT_ID=$(orch "$ORCHESTRATOR_URL/api/v1/integrations" | python3 -c "
import sys, json
ints = json.load(sys.stdin).get('resources', [])
ids = [i['id'] for i in ints if i.get('integration_type')=='llm_provider']
print(ids[0] if ids else '')
")
if [[ -z "$LLM_INT_ID" ]]; then
  RESP=$(orch -X POST "$ORCHESTRATOR_URL/api/v1/integrations" -d "{
    \"name\": \"Vertex LLM Proxy\",
    \"integration_type\": \"llm_provider\",
    \"scope\": \"global\",
    \"enabled\": true,
    \"management_credential_id\": \"$LLM_CRED_ID\",
    \"configuration\": {
      \"integration_type\": \"llm_provider\",
      \"provider_hint\": \"openai\",
      \"base_url\": \"$LLM_BASE_URL\",
      \"allow_http\": true
    }
  }")
  LLM_INT_ID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
  [[ -z "$LLM_INT_ID" ]] && die "LLM integration create failed: $RESP"
  ok "Created — $LLM_INT_ID"
else
  ok "Found — $LLM_INT_ID"
fi
orch -X POST "$ORCHESTRATOR_URL/api/v1/integrations/$LLM_INT_ID/validate" >/dev/null 2>&1 && ok "LLM integration validated" || red "  WARNING: LLM validation failed"
orch -X POST "$ORCHESTRATOR_URL/api/v1/integrations/$LLM_INT_ID/refresh" >/dev/null 2>&1 && ok "LLM models refreshed" || true

step "Selecting LLM model $LLM_MODEL_NAME"
LLM_MODEL_ID=""
for _try in 1 2 3 4 5 6; do
  LLM_MODEL_ID=$(orch "$ORCHESTRATOR_URL/api/v1/integrations/$LLM_INT_ID/models" | python3 -c "
import sys, json, os
want = os.environ.get('LLM_MODEL_NAME','claude-haiku-4-5')
items = json.load(sys.stdin).get('resources', [])
exact = [i for i in items if i.get('model_id')==want or i.get('name')==want]
pref = [i for i in items if want in (i.get('model_id') or '') or want in (i.get('name') or '')]
pick = (exact or pref or items)
print(pick[0]['id'] if pick else '')
print('candidates:', [(i.get('model_id'), i.get('name'), i.get('enabled')) for i in items], file=sys.stderr)
")
  [[ -n "$LLM_MODEL_ID" ]] && break
  sleep 3
done
[[ -z "$LLM_MODEL_ID" ]] && die "No LLM models discovered on integration $LLM_INT_ID — is $LLM_BASE_URL reachable from Orchestrator pods?"
ok "LLM model record $LLM_MODEL_ID"
orch -X PATCH "$ORCHESTRATOR_URL/api/v1/integrations/$LLM_INT_ID/models/$LLM_MODEL_ID" \
  -d '{"enabled": true, "is_default": true}' >/dev/null 2>&1 || true

# ── Part 4: AAP job template IDs ─────────────────────────────────────────────
step "Discovering AAP job template IDs"

require_jt() {
  local name="$1" var="$2" id
  id=$(aap_id_by_name /api/controller/v2/job_templates "$name")
  [[ -z "$id" ]] && die "Job template '$name' not found"
  printf -v "$var" '%s' "$id"
  ok "$name JT: $id"
}

require_jt "SELinux - Apply Remediation" REMEDIATE_JT_ID
require_jt "SELinux - Post-Remediation Observation" OBSERVATION_JT_ID
require_jt "SELinux - Commit Remediations" COMMIT_JT_ID
require_jt "SELinux - Sync and Deploy" SYNC_JT_ID
require_jt "SELinux - Notify Investigation" NOTIFY_JT_ID

# ── Part 5: Service account (must exist before publish so the trigger allowlist is set)
# Re-runs must NOT rotate the client secret — that invalidates AAP credential 7.
step "Service account for EDA webhook"
SA_NAME="SELinux EDA Forwarder"
SA_CREATED=0
SA_ID=$(orch "$ORCHESTRATOR_URL/api/v1/service_accounts" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('resources', [])
ids = [i['id'] for i in items if i.get('name')=='$SA_NAME']
print(ids[0] if ids else '')
")
if [[ -z "$SA_ID" ]]; then
  RESP=$(orch -X POST "$ORCHESTRATOR_URL/api/v1/service_accounts" -d "{
    \"name\": \"$SA_NAME\",
    \"description\": \"Token used by AAP Forward to Orchestrator job template\",
    \"project_id\": \"$PROJECT_ID\"
  }")
  SA_ID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
  [[ -z "$SA_ID" ]] && die "Service account create failed: $RESP"
  SA_CREATED=1
  ok "Created service account — $SA_ID"
else
  ok "Found service account — $SA_ID"
fi

# ── Part 6: Create / update and publish workflow ─────────────────────────────
step "Building workflow definition"
WFDEF=$(LLM_MODEL_ID="$LLM_MODEL_ID" LLM_CRED_ID="$LLM_CRED_ID" AAP_INT_ID="$AAP_INT_ID" AAP_CRED_ID="$AAP_CRED_ID" \
  COMMIT_JT_ID="$COMMIT_JT_ID" SYNC_JT_ID="$SYNC_JT_ID" NOTIFY_JT_ID="$NOTIFY_JT_ID" \
  OBSERVATION_JT_ID="$OBSERVATION_JT_ID" PROJECT_ID="$PROJECT_ID" WF_NAME="$WF_NAME" \
  SA_ID="$SA_ID" \
  python3 -c "
import json, os
with open('$SCRIPT_DIR/workflow-definition.json') as f:
    d = json.load(f)
d['project_id'] = os.environ['PROJECT_ID']
d['name'] = os.environ['WF_NAME']
# Fixed JTs by node id. nRemDev/nRemProd keep job_template_name expressions.
jt_by_node = {
    'nFetchDev': int(os.environ['COMMIT_JT_ID']),
    'nFetchProd': int(os.environ['COMMIT_JT_ID']),
    'nSyncDev': int(os.environ['SYNC_JT_ID']),
    'nSyncProd': int(os.environ['SYNC_JT_ID']),
    'nObsDev': int(os.environ['OBSERVATION_JT_ID']),
    'nObsProd': int(os.environ['OBSERVATION_JT_ID']),
    'nNotify': int(os.environ['NOTIFY_JT_ID']),
}
for trig in d['workflow_definition'].get('triggers', []):
    params = trig.setdefault('parameters', {})
    if trig.get('type') == 'eda_trigger':
        params['authorized_service_account_ids'] = [os.environ['SA_ID']]
for node in d['workflow_definition']['nodes']:
    params = node.setdefault('parameters', {})
    if node['type'] == 'agentic':
        params['llm_model_id'] = os.environ['LLM_MODEL_ID']
        params['credential_id'] = os.environ['LLM_CRED_ID']
    elif node['type'] == 'aap_job_template':
        params['credential_id'] = os.environ['AAP_CRED_ID']
        params['integration_id'] = os.environ['AAP_INT_ID']
        if node['id'] in jt_by_node:
            params['job_template_id'] = jt_by_node[node['id']]
            params.pop('job_template_name', None)
        else:
            params.setdefault('organization_name', 'Default')
            params.pop('job_template_id', None)
print(json.dumps(d))
")

step "Creating Orchestrator workflow"
WF_ID=$(orch_id_by_name /api/v1/workflows "$WF_NAME")
if [[ -n "$WF_ID" ]]; then
  ok "Workflow already exists — $WF_ID (updating definition)"
  RESP=$(orch -X PATCH "$ORCHESTRATOR_URL/api/v1/workflows/$WF_ID" -d "$WFDEF")
  echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); raise SystemExit(0 if d.get('id') else 1)" 2>/dev/null \
    || die "Workflow update failed: $RESP"
else
  RESP=$(orch -X POST "$ORCHESTRATOR_URL/api/v1/workflows" -d "$WFDEF")
  WF_ID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
  [[ -z "$WF_ID" ]] && die "Workflow create failed: $RESP"
  ok "Workflow created — $WF_ID"
fi

VER=$(orch "$ORCHESTRATOR_URL/api/v1/workflows/$WF_ID" | python3 -c "import sys,json; print(json.load(sys.stdin).get('current_version') or 1)")
step "Publishing workflow version $VER"
PUB=$(orch -X POST "$ORCHESTRATOR_URL/api/v1/workflows/$WF_ID/versions/$VER/publish" -d '{}' || true)
PUB_VER=$(printf '%s' "${PUB:-{}}" | python3 -c "
import sys, json
raw = sys.stdin.read().strip() or '{}'
try:
    d = json.loads(raw)
except json.JSONDecodeError:
    print('(non-json publish response)')
    raise SystemExit(0)
if not isinstance(d, dict):
    print(d)
    raise SystemExit(0)
print(d.get('published_version_number') or d.get('published_version') or (d.get('version') or {}).get('status') or d.get('status') or 'ok')
")
ok "Published — $PUB_VER"

# ── Part 7: Issue SA secret and patch AAP only when needed ───────────────────
# New SA, or ROTATE_SA_SECRET=1. Re-runs keep the existing AAP credential.
if [[ "$SA_CREATED" == "1" || "${ROTATE_SA_SECRET:-0}" == "1" ]]; then
  step "Issuing service-account client credentials"
  RESP=$(orch -X POST "$ORCHESTRATOR_URL/api/v1/service_accounts/$SA_ID/credentials" -d '{"credential_type":"client_credentials"}')
  SA_CLIENT_ID=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('identifier',''))" 2>/dev/null)
  SA_CLIENT_SECRET=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('client_secret') or '')" 2>/dev/null)
  if [[ -z "$SA_CLIENT_ID" || -z "$SA_CLIENT_SECRET" ]]; then
    red "  Could not mint a new client secret (maybe at max credentials). Rotating first credential."
    CRED0=$(orch "$ORCHESTRATOR_URL/api/v1/service_accounts/$SA_ID/credentials" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('resources', [])
print(items[0]['id'] if items else '')
")
    [[ -z "$CRED0" ]] && die "No service-account credentials to rotate: $RESP"
    RESP=$(orch -X POST "$ORCHESTRATOR_URL/api/v1/service_accounts/$SA_ID/credentials/$CRED0/rotate" -d '{}')
    SA_CLIENT_ID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('identifier',''))" 2>/dev/null)
    SA_CLIENT_SECRET=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('client_secret') or '')" 2>/dev/null)
  fi
  [[ -z "$SA_CLIENT_ID" || -z "$SA_CLIENT_SECRET" ]] && die "Failed to issue service-account secret: $RESP"
  export SA_CLIENT_ID SA_CLIENT_SECRET
  ok "Issued client_id $SA_CLIENT_ID"

  step "Updating AAP Orchestrator credential with service-account client credentials"
  AAP_ORCH_CRED_ID=$(aap_id_by_name /api/controller/v2/credentials "Automation Orchestrator")
  [[ -z "$AAP_ORCH_CRED_ID" ]] && die "AAP credential 'Automation Orchestrator' not found"
  PATCH_BODY=$(SA_CLIENT_ID="$SA_CLIENT_ID" SA_CLIENT_SECRET="$SA_CLIENT_SECRET" ORCHESTRATOR_URL="$ORCHESTRATOR_URL" python3 -c "
import json, os
print(json.dumps({
  'inputs': {
    'orchestrator_url': os.environ['ORCHESTRATOR_URL'],
    'orchestrator_username': os.environ['SA_CLIENT_ID'],
    'orchestrator_password': os.environ['SA_CLIENT_SECRET'],
  }
}))
")
  aap -X PATCH "$AAP_URL/api/controller/v2/credentials/$AAP_ORCH_CRED_ID/" -d "$PATCH_BODY" >/dev/null
  ok "AAP credential $AAP_ORCH_CRED_ID now uses service-account client credentials"
else
  step "Keeping existing AAP Orchestrator credential"
  ok "Not rotating SA secret (set ROTATE_SA_SECRET=1 to mint a new one and patch AAP)"
fi

echo
green "═══════════════════════════════════════════════"
green "  SELinux Orchestrator workflow ready!"
green "═══════════════════════════════════════════════"
echo "  Orchestrator URL:      $ORCHESTRATOR_URL"
echo "  API docs:              $ORCHESTRATOR_URL/docs"
echo "  Workflow ID:           $WF_ID"
echo "  Webhook:               POST /api/v1/webhooks/eda/selinux"
echo "  Project:               $PROJECT_ID"
echo "  Service account:       $SA_ID ($SA_NAME)"
echo "  LLM integration:       $LLM_INT_ID"
echo "  LLM model:             $LLM_MODEL_ID ($LLM_MODEL_NAME)"
echo "  Commit Remediations JT: $COMMIT_JT_ID"
echo "  Sync and Deploy JT:     $SYNC_JT_ID"
echo "  Notify Investigation JT:$NOTIFY_JT_ID"
echo "  Apply Remediation JT:   $REMEDIATE_JT_ID (launched via job_template_name expression)"
echo "  Observation JT:         $OBSERVATION_JT_ID"
echo "  AAP Credential:        $AAP_CRED_ID"
echo "  LLM Credential:        $LLM_CRED_ID"
echo
echo "Trigger via EDA event stream:"
echo "  curl -k -u selinux:redhat123 -X POST \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"action\": \"selinux_analysis\", \"host\": \"selinux-demo\"}' \\"
echo "    'https://aap-aap.apps.sno.stoleas.home/eda-event-streams/api/eda/v1/external_event_stream/b86e11ce-d4e0-45bb-a867-9ab79f7c32ad/post/'"
echo
echo "Approve via ServiceNow (polling is automatic):"
echo "  Navigate to ServiceNow → Change → Open → find the SELinux change ticket → Approve"
