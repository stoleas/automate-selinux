# SELinux Automated Remediation

AI-assisted SELinux enablement pipeline on Ansible Automation Platform (AAP) 2.7 and Automation Orchestrator 2026.8.

The pipeline follows the workflow from the Red Hat Summit deck *Deploying SELinux successfully in production environments*: provision a RHEL VM, transition through SELinux states, collect AVC denials, then let the Orchestrator **triage and route** — auto-patch in dev, human approval in prod, investigate when no safe fix is known, or stop on fallback. Remediations stay in permissive mode.

## Flow

```
Collect and Notify (AAP job template)
    → Collects AVC denials + audit2allow output from the demo VM
    → POSTs event to EDA (host, environment, force_route, AVCs)
    → EDA rule fires "Forward to Orchestrator"
    → Orchestrator webhook (/api/v1/webhooks/eda/selinux)
    → Orchestrator workflow:
        AI Triage (agentic) → Normalize Route (python script) → Switch
          Auto-Patch (Dev):     Commit → Sync → dynamic Apply Remediation → Observe
          Approval (Prod):      AO approval → same commit/sync/remediate/observe chain
          Investigate:          second agentic → parse script → Notify Investigation
          Fallback:             python script, no mutation
```

The Automation Orchestrator owns the workflow DAG (`switch`, `script`, `approval`, `agentic`, `aap_job_template`). AAP provides leaf job templates only. EDA routes events. Prod uses the native Orchestrator approval node. ServiceNow playbooks remain in the repo for the earlier ITSM-gated DAG; they are not on this canvas.

## Architecture

| Component | Role |
|---|---|
| **KVM / libvirt host** | Provisions and snapshots the demo RHEL VM |
| **Demo VM** | RHEL with SELinux in permissive mode and a deliberately mislabeled httpd app (`/srv/webapp/` as `var_t`) to guarantee AVC denials |
| **AAP 2.7** | Automation Controller (job templates), Event-Driven Ansible (event stream + rulebook) |
| **Automation Orchestrator** | Switch-routed DAG: triage, env split, prod approval, investigate, fallback |
| **LLM integration** | Native Orchestrator agentic nodes (OpenAI-compatible proxy). Lab has no MCP tools yet. |
| **Git stand-in** | GitHub `stoleas/automate-selinux` stands in for Gitea; commit/sync JTs publish `template_name` via `set_stats` |
| **Notification stand-in** | Notify Investigation JT prints a structured notice (Mattermost is not in the lab) |

### Orchestrator workflow nodes

| Node | Type | Purpose |
|---|---|---|
| Webhook trigger | `eda_trigger` | `POST /api/v1/webhooks/eda/selinux` |
| AI Triage Agent | `agentic` | Findings JSON plus a `route` recommendation |
| Normalize Route | `script` (python) | Honors `force_route`, else AI route, else env heuristic |
| Route Decision | `switch` | `auto_patch_dev` / `approval_required_prod` / `investigate` / `fallback` |
| Commit Remediations | AAP JT | Artifact + `set_stats.template_name` (Lightspeed/Gitea stand-in) |
| Sync and Deploy | AAP JT | Re-publishes `template_name` for the dynamic node |
| Run SELinux Remediation | AAP JT **expression** | `${nSync*.artifacts.template_name}` → Apply Remediation |
| Post-Remediation Observation | AAP JT | Re-collect AVCs; stay permissive |
| Approve Production Patch | `approval` | Prod branch only; reject ends the run |
| Investigate | `agentic` | No known safe remediation |
| Parse Investigation Result | `script` (python) | Headline/body for notify |
| Notify Investigation | AAP JT | Mattermost stand-in |
| Fallback | `script` (python) | Explicit no-op dead-end |

## Project structure

```
automate-selinux/
├── ansible.cfg
├── inventory/
│   ├── hosts.yml                         # KVM host + demo VM + localhost
│   └── group_vars/
│       ├── all/
│       │   ├── vars.yml                  # Shared vars (VM, SELinux, EDA, ServiceNow, Orchestrator)
│       │   └── vault.yml                 # Vault-encrypted secrets
│       └── kvm_hosts.yml                 # libvirt connection details
├── collections/
│   └── requirements.yml
├── playbooks/
│   ├── 01-provision-vm.yml               # Create RHEL VM via virt-install + kickstart
│   ├── 02-snapshot-baseline.yml          # Snapshot with SELinux disabled
│   ├── 03-restore-snapshot.yml           # Restore baseline snapshot
│   ├── 04-enable-selinux-permissive.yml  # Permissive + auditd + relabel + reboot
│   ├── 05-snapshot-permissive.yml        # Snapshot permissive state
│   ├── 06-collect-avc-logs.yml           # ausearch + audit2allow
│   ├── 07-ai-analysis.yml                # Legacy AI playbook (AI now runs in Orchestrator)
│   ├── 08-generate-report.yml            # Markdown report from AI findings
│   ├── 09-apply-remediation.yml          # Apply remediations
│   ├── 10-collect-and-notify.yml         # Collect AVCs + POST to EDA
│   ├── 11-forward-to-orchestrator.yml    # Forward EDA event to Orchestrator
│   ├── 12-servicenow-create-change.yml   # Create ServiceNow Normal Change
│   ├── 13-servicenow-check-approval.yml  # Poll approval field
│   ├── 14-observe-post-remediation.yml   # Post-remediation AVC observation
│   ├── 15-servicenow-setup.yml           # One-time ServiceNow demo artifacts
│   ├── 16-generate-avc-denials.yml       # Utility: seed extra AVCs (not in demo DAG)
│   ├── 17-commit-remediations.yml        # Artifact + template_name (Gitea stand-in)
│   ├── 18-sync-and-deploy.yml            # Re-publish template_name for dynamic JT
│   ├── 19-notify-investigation.yml       # Investigation notice (Mattermost stand-in)
│   └── site.yml                          # Local full-pipeline orchestration
├── roles/
│   ├── vm_provision/                     # KVM/libvirt + kickstart
│   ├── demo_app/                         # httpd + mislabeled content
│   ├── selinux_baseline/                 # Mode, auditd, relabel, reboot
│   ├── selinux_collect/                  # AVC logs + audit2allow
│   ├── selinux_analyze/                  # Legacy AI analysis role
│   └── selinux_remediate/                # fcontext / boolean / port / module
├── templates/
│   └── selinux-report.md.j2
├── rulebooks/
│   └── selinux-monitor.yml               # EDA: event stream → Orchestrator
├── orchestrator/
│   ├── workflow-definition.json          # Orchestrator workflow DAG
│   └── setup.sh                          # Deploy / publish workflow
└── controller/
    ├── setup.yml                         # CaC: AAP objects via infra.aap_configuration
    ├── job-templates.yml                 # JT reference definitions
    ├── workflow-template.yml             # Legacy reference (Orchestrator owns workflows)
    └── eda-activation.yml                # EDA event stream + activation
```

## Prerequisites

- AAP 2.7 (Automation Controller + Event-Driven Ansible)
- Automation Orchestrator with an LLM integration (OpenAI-compatible endpoint)
- KVM/libvirt host with a RHEL boot ISO
- ServiceNow instance with Change Management
- Ansible collections from `collections/requirements.yml`
- Ansible Vault password file for secrets in `inventory/group_vars/all/vault.yml`

## Configuration

Edit `inventory/group_vars/all/vars.yml` for your environment:

| Variable area | Examples |
|---|---|
| VM | `vm_name`, `vm_bridge`, CPU/memory/disk, RHEL ISO path |
| SELinux | `selinux_policy`, `selinux_policy_module_name`, observation period |
| AI proxy | `vertex_ai_proxy_url` (OpenAI-compatible base URL) |
| Orchestrator | `orchestrator_url` |
| EDA | `aap_hostname`, `eda_event_stream_id`, webhook credentials |
| ServiceNow | instance, username, assignment group, CMDB CI, poll timeout |

Secrets go in `inventory/group_vars/all/vault.yml` (vault-encrypted): VM passwords, RHSM credentials, EDA webhook password, ServiceNow password.

Update `inventory/hosts.yml` with your KVM host and demo VM inventory entries. Do not commit real host addresses or credentials.

## Setup

### 1. Install collections

```bash
ansible-galaxy collection install -r collections/requirements.yml
```

### 2. Provision AAP objects

```bash
ansible-playbook controller/setup.yml -i localhost, \
  -e aap_password=<password> \
  -e credential_ssh_key_file=~/.ssh/id_rsa
```

This creates the project, inventory, credentials, and job templates via `infra.aap_configuration`.

Add a `localhost` host to the AAP inventory (`ansible_connection: local`) so playbooks that target `localhost` (ServiceNow, Generate Report) load `group_vars` and vault. Store the ServiceNow password as a host variable or attach the Vault credential to those job templates.

Ensure `ask_variables_on_launch: true` on job templates that receive Orchestrator extras: Collect and Notify, Forward to Orchestrator, Commit Remediations, Sync and Deploy, Apply Remediation, Post-Remediation Observation, Notify Investigation.

### 3. ServiceNow demo artifacts (once)

```bash
ansible-playbook playbooks/15-servicenow-setup.yml -i localhost, \
  -e "@inventory/group_vars/all/vars.yml" \
  -e "@inventory/group_vars/all/vault.yml" \
  --vault-password-file <vault-password-file>
```

Creates the assignment group, CMDB CI for the demo host, and enables email notifications. Idempotent.

### 4. Deploy the Orchestrator workflow

```bash
AAP_PASS=<password> bash orchestrator/setup.sh
```

Discovers AAP Gateway and LLM integrations, looks up job template IDs, patches `workflow-definition.json`, creates the workflow, and publishes it. Set `ORCHESTRATOR_URL` / `AAP_URL` as needed for your environment.

### 5. Lab VM (first time)

Run in order (or use the corresponding AAP job templates):

1. Provision VM  
2. Snapshot baseline  
3. Enable SELinux permissive (+ auditd, relabel, reboot)  
4. Snapshot permissive  

The demo app under `/srv/webapp/` is intentionally labeled so httpd generates AVC denials in permissive mode.

## Running the demo

### Ensure the VM is ready

SELinux should be **Permissive**. If needed, revert the libvirt snapshot `selinux-permissive-baseline` on the KVM host, wait for boot, and confirm with `getenforce`.

### Optional — generate extra AVCs

Before Collect and Notify, you can seed additional denials (httpd mislabels, CGI, nonstandard port bind, vsftpd) without starting the Orchestrator flow:

1. Launch **SELinux - Generate AVC Denials** (playbook `16-generate-avc-denials.yml`)
2. Then launch **SELinux - Collect and Notify** as usual

Defaults keep the VM in **permissive** mode and restore dontaudit rules on cleanup. Prompt-on-launch variables include `target_selinux_mode`, `disable_dontaudit`, and `cleanup_after`.

### Verify EDA

In AAP → Event-Driven Ansible → Activations, **SELinux Monitor** should be Running.

### Trigger

**Option A — real collection:** Launch **SELinux - Collect and Notify**. Extra vars `demo_environment` (`dev`/`prod`) and `force_route` (`auto_patch_dev` / `approval_required_prod` / `investigate` / `fallback` / empty) control the switch. Empty `force_route` lets the triage agent pick.

**Option B — synthetic event:** POST JSON to your EDA event stream URL with Basic auth. Required fields:

```json
{
  "action": "selinux_analysis",
  "host": "selinux-demo",
  "environment": "dev",
  "force_route": "",
  "avc_count": "5",
  "avc_denials": "<raw ausearch AVC output>",
  "audit2allow_output": "<audit2allow suggestions>",
  "timestamp": "<ISO-8601>"
}
```

### Watch the chain

1. EDA matches `selinux_analysis` → launches Forward to Orchestrator
2. Event reaches Orchestrator webhook `/api/v1/webhooks/eda/selinux`
3. AI Triage → Normalize Route → Switch
4. **Dev:** Commit → Sync → Apply Remediation (dynamic JT name) → Observe
5. **Prod:** execution pauses on **Approve Production Patch**. Approve via Orchestrator UI or `PATCH /api/v1/approvals/{id}` with `{"status":"approved"}`. Reject ends the run.
6. **Investigate:** second agent → parse → Notify Investigation job
7. **Fallback:** script node completes with no mutation

API reference: `https://orchestrator.apps.sno.stoleas.home/docs` (`/api_docs/v1/openapi.json`).

Monitor AAP **Jobs** and the Orchestrator workflow run.

### Approve production (AO native approval)

```bash
curl -sk -X PATCH "$ORCH/api/v1/approvals/$APPROVAL_ID" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"status": "approved"}'
```

ServiceNow create/poll playbooks are still in the repo (playbooks 12/13) but are **not** on this DAG. After approval on the prod path, Apply Remediation runs, then observation. The system remains in **permissive** mode.

### Expected remediation outcome

- HTTP index and CGI endpoints return 200  
- Remaining AVC denials near zero (or clearly reduced)  
- Observation notes readiness for an enforcing transition only after a longer observation period in a real environment  

## Resetting the demo

Revert the VM to the `selinux-permissive-baseline` libvirt snapshot, wait for boot, confirm `getenforce` is Permissive, then launch Collect and Notify again.

If the snapshot leaves SELinux disabled or the domain is orphaned from libvirt, run the `selinux_baseline` role against the VM (see playbook `04-enable-selinux-permissive.yml`) to set permissive, create `/.autorelabel`, and reboot.

## Design decisions

1. **Boot ISO + Kickstart** — matches production RHEL installs (not cloud images).  
2. **Orchestrator owns the DAG** — AAP job templates are leaves; no Controller workflow templates required for the live demo path.
3. **AI-evaluated remediation** — the prompt treats audit2allow as advisory; prefers `semanage fcontext` / booleans over overly broad custom modules when possible.
4. **Switch-routed env split** — dev auto-patches; prod pauses on a native Orchestrator approval node; investigate and fallback are first-class routes.
5. **Dynamic remediation JT** — `job_template_name` is `${nSync*.artifacts.template_name}` from the commit/sync hop (CVE-chart pattern).
6. **Stay permissive after fix** — models monitoring before enforcing.
7. **Snapshots** — fast demo reset without full reprovision.  

## Demo talking points

- **Collect and Notify** — one simple job: collect logs and emit an event with `environment` / `force_route`. Intelligence lives downstream.
- **EDA** — event router; matches `selinux_analysis` and hands off to the Orchestrator.
- **Orchestrator** — owns a real DAG: switch, approval, scripts, two agents, dynamically named AAP jobs.
- **AI Triage** — native agentic node; returns findings plus a route.
- **Dev vs prod** — same VM, different path. Prod is the only branch that waits for a human.
- **Git in the loop** — commit/sync hops model Lightspeed → Gitea → AAP project sync; the next node launches whatever JT name they published.
- **Investigate** — when there is no safe patch, a second agent writes a notice instead of mutating the host.
- **After remediation** — AVCs drop; system stays permissive for continued observation.  

## Troubleshooting

| Symptom | Fix |
|---|---|
| AI Analysis connection refused | Ensure the OpenAI-compatible proxy / LLM integration is up and validated in Orchestrator |
| Vault password not found | Attach the Vault credential to affected job templates |
| Collect cannot SSH to VM | Confirm the VM is running; restore the permissive snapshot if needed |
| EDA activation FAILED | Check activation logs; restart the activation |
| Forward / Report / Remediation missing extras | Enable **Prompt on launch → Variables** (`ask_variables_on_launch`) on those templates |
| EDA event stream 401 | Check event stream Basic auth credentials |
| Orchestrator 401 | Re-authenticate; refresh the Orchestrator credential in AAP |
| Workflow not triggering | Confirm the workflow is published; re-run `orchestrator/setup.sh`. 2026.8 webhooks need a service-account Bearer token at `POST /api/v1/webhooks/eda/selinux` |
| AAP node SSRF / DNS | Orchestrator workers cannot resolve `*.apps.sno.stoleas.home`. Point the AAP integration at `http://aap.aap.svc` (`allow_http: true`) and allowlist that host in ConfigMap `automation-orchestrator-admin-settings` |
| ServiceNow 401 / 403 | Check credentials; ensure Change Management is available on the instance |
| Change stuck in New | Poll/set the `approval` field, not `state` (legacy ServiceNow DAG) |
| Approval poll timeout | Raise `servicenow_approval_timeout_minutes` in `vars.yml` (legacy ServiceNow DAG) |
| Prod path stuck on approval | `GET /api/v1/approvals?status=pending` then `PATCH` `{"status":"approved"}` |
| Switch always takes fallback | Confirm payload `environment` / `force_route` and that Normalize Route printed a `route` |
| Dynamic remediation JT 404 | Commit/Sync must `set_stats.template_name` to an existing JT (default `SELinux - Apply Remediation`) |
| `servicenow_change_sys_id` undefined | Legacy ServiceNow DAG only — `${n3a.artifacts.servicenow_change_sys_id}` |
| JSON parse skipped (`AnsibleUnsafeText`) | Conditionals must accept `type_debug in ['str', 'AnsibleUnsafeText']` |
| LLM output wrapped in `<string>` or markdown fences | Strip wrappers with `regex_replace` before `from_json` |
| `uri` `.json` missing | Set `return_content: true` on the `uri` task |
| Local `ansible-playbook` fails on yaml callback | Override with `ANSIBLE_STDOUT_CALLBACK=default` on newer ansible-core |

## License

Internal demo / lab project. Adjust as needed for your organization.
