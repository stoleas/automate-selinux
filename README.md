# SELinux Automated Remediation

AI-assisted SELinux enablement pipeline on Ansible Automation Platform (AAP) 2.7 with ServiceNow change management.

The pipeline follows the workflow from the Red Hat Summit deck *Deploying SELinux successfully in production environments*: provision a RHEL VM, transition through SELinux states, collect and analyze AVC denials with AI, gate remediation through ITSM approval, then apply fixes and observe — staying in permissive mode.

## Flow

```
Collect and Notify (AAP job template)
    → Collects AVC denials + audit2allow output from the demo VM
    → POSTs event to EDA event stream
    → EDA rule fires "Forward to Orchestrator"
    → Orchestrator webhook (/api/v1/webhooks/selinux)
    → Orchestrator workflow:
        AI Analysis (native agentic node)
        → Generate Report (AAP)
        → Create ServiceNow Change (AAP)
        → Poll ServiceNow Approval (AAP)
        → Apply Remediation (AAP)
        → Post-Remediation Observation (AAP, stays permissive)
```

The Automation Orchestrator owns the workflow DAG. AAP provides leaf job templates only. EDA routes events. ServiceNow is the change-management approval gate.

## Architecture

| Component | Role |
|---|---|
| **KVM / libvirt host** | Provisions and snapshots the demo RHEL VM |
| **Demo VM** | RHEL with SELinux in permissive mode and a deliberately mislabeled httpd app (`/srv/webapp/` as `var_t`) to guarantee AVC denials |
| **AAP 2.7** | Automation Controller (job templates), Event-Driven Ansible (event stream + rulebook) |
| **Automation Orchestrator** | Workflow DAG: AI analysis → report → ServiceNow → remediation → observation |
| **LLM integration** | Native Orchestrator agentic node (OpenAI-compatible proxy) |
| **ServiceNow** | Normal Change ticket for remediation approval |

### Orchestrator workflow nodes

| Node | Type | Purpose |
|---|---|---|
| Webhook trigger | `webhook_trigger` | Receives EDA events on path `selinux` |
| AI Analysis | `agentic` | Analyzes AVC denials via LLM; returns structured JSON findings |
| Generate Report | AAP job template | Renders markdown report from AI findings |
| Create ServiceNow Change | AAP job template | Creates a Normal Change ticket with CI link + assignment group |
| Check ServiceNow Approval | AAP job template | Polls the ticket `approval` field until approved, rejected, or timeout |
| Apply Remediation | AAP job template | Applies fcontext, booleans, port labels, and/or custom policy modules |
| Post-Remediation Observation | AAP job template | Re-collects AVCs, compares to pre-remediation count, stays permissive |

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

Ensure `ask_variables_on_launch: true` on job templates that receive Orchestrator extras: Generate Report, Forward to Orchestrator, Create ServiceNow Change, Check ServiceNow Approval, Apply Remediation, and Post-Remediation Observation.

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

**Option A — real collection:** Launch **SELinux - Collect and Notify**. It collects AVCs from the VM and POSTs to the EDA event stream.

**Option B — synthetic event:** POST JSON to your EDA event stream URL with Basic auth. Required fields:

```json
{
  "action": "selinux_analysis",
  "host": "selinux-demo",
  "avc_count": "5",
  "avc_denials": "<raw ausearch AVC output>",
  "audit2allow_output": "<audit2allow suggestions>",
  "timestamp": "<ISO-8601>"
}
```

### Watch the chain

1. EDA matches `selinux_analysis` → launches Forward to Orchestrator  
2. Event reaches Orchestrator webhook `/api/v1/webhooks/selinux`  
3. Workflow: AI Analysis → Generate Report → Create ServiceNow Change → poll approval  

Monitor AAP **Jobs** and the Orchestrator workflow run. The approval node polls ServiceNow every 30 seconds (configurable).

### Approve in ServiceNow

Open the Normal Change ticket (short description like *SELinux remediation for selinux-demo*). Set the **approval** field to **Approved** (not `state` — many instances lock state transitions via business rules).

Via REST:

```bash
curl -sk -X PATCH -u "$SN_USER:$SN_PASS" \
  -H "Content-Type: application/json" \
  -d '{"approval": "approved"}' \
  "https://$SN_INSTANCE.service-now.com/api/now/table/change_request/$CHANGE_SYS_ID"
```

After approval, Apply Remediation runs, then Post-Remediation Observation. The system remains in **permissive** mode.

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
4. **ServiceNow gate** — real ITSM approval instead of a generic Orchestrator approval node.  
5. **Stay permissive after fix** — models monitoring before enforcing.  
6. **Snapshots** — fast demo reset without full reprovision.  

## Demo talking points

- **Collect and Notify** — one simple job: collect logs and emit an event. Intelligence lives downstream.  
- **EDA** — event router; matches `selinux_analysis` and hands off to the Orchestrator.  
- **Orchestrator** — owns the DAG: AI, report, ITSM gate, remediation, observation.  
- **AI Analysis** — runs natively in the Orchestrator via LLM integration; returns structured findings.  
- **ServiceNow** — remediation enters the customer change process; nothing applies until approved.  
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
| Workflow not triggering | Confirm the workflow is published; re-run `orchestrator/setup.sh` |
| ServiceNow 401 / 403 | Check credentials; ensure Change Management is available on the instance |
| Change stuck in New | Poll/set the `approval` field, not `state` |
| Approval poll timeout | Raise `servicenow_approval_timeout_minutes` in `vars.yml` |
| `servicenow_change_sys_id` undefined | Orchestrator must pass `${n3a.artifacts.servicenow_change_sys_id}` |
| JSON parse skipped (`AnsibleUnsafeText`) | Conditionals must accept `type_debug in ['str', 'AnsibleUnsafeText']` |
| LLM output wrapped in `<string>` or markdown fences | Strip wrappers with `regex_replace` before `from_json` |
| `uri` `.json` missing | Set `return_content: true` on the `uri` task |
| Local `ansible-playbook` fails on yaml callback | Override with `ANSIBLE_STDOUT_CALLBACK=default` on newer ansible-core |

## License

Internal demo / lab project. Adjust as needed for your organization.
