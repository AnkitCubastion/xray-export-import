# Xray Server → Cloud Migration Toolkit  (MFTBCTRKD → TEST)

A **lossless-by-design**, resumable migration of Xray test-management data from
**Jira Server 8.4.0 + Xray Server/DC** to **Jira Cloud + Xray Cloud**.

Built because the standard Jira migration (JCMA) moved the Jira issues but **not**
the Xray plugin data — test types, manual steps, Gherkin/Generic definitions,
preconditions, Test ↔ Test Set ↔ Test Plan ↔ Test Execution links, and all run
results/evidence live in Xray's own storage and were left behind.

| File | Purpose |
|---|---|
| `config.ps1` | Central settings (URLs, project keys, throttles). **Edit this first.** No secrets. |
| `XrayMig.Common.ps1` | Shared helpers: auth, retry, throttle, ADF, TLS trust, token refresh, key map. |
| `Phase0_Preflight.ps1` | **Go/No-Go checks** (read-only). Verifies the Xray issue types exist on the Cloud project — the #1 past failure. |
| `Phase1_Export_Server.ps1` | Extracts **everything** from the server into `export\MFTBCTRKD\`. |
| `Phase2_Import_Cloud.ps1` | Rebuilds it in Cloud via Jira REST v3 + Xray GraphQL + Xray import. |
| `Run-Migration.ps1` | One-stop orchestrator (preflight → export → import). |
| `README_MIGRATION.md` | This runbook. |

---

## Why the earlier scripts lost data (and how this fixes it)

Across the previous attempts in this folder, three classes of failure recurred —
all confirmed against the official APIs (2026-06):

1. **They only copied the Jira shell.** `/rest/api/2/search` and the XML export
   return summary/description/labels but **none** of Xray's substance. This
   toolkit reads Xray data via the **Xray Server raven API**
   (`/rest/raven/1.0/api/...`) and writes it via **Xray Cloud GraphQL + import**.
2. **They called Server (`raven`) endpoints against the Cloud instance.** Xray
   Cloud has **no** `/rest/raven/...`; it uses `/api/v2/graphql` and
   `/api/v2/import/execution`. Wrong target API = nothing migrates.
3. **The two HTTP 400s in your logs:**
   - `{"errors":{"issuetype":"Specify a valid issue type"}}` — the Xray issue
     types weren't on the Cloud project's scheme, or Server type ids
     (10100–10105) were reused (Cloud ids differ). **Phase 0 now blocks the run
     until the 6 Xray types exist on `TEST`**, and the importer resolves Cloud
     type ids by name.
   - `{"errors":{"description":"Operation value must be an Atlassian Document …"}}`
     — Jira Cloud v3 requires **ADF**, not a plain string. Every description and
     comment is now converted to ADF.

### Additional hardening verified by an API + code audit

- **Self-signed source TLS** (`dta-jira*.corpintra/tbintra`) is now trusted —
  scoped to the source hosts only (PS 5.1 callback + PS 7 `-SkipCertificateCheck`).
  Without this, the export connected to nothing.
- **Xray Cloud token auto-refresh** — the ~24h JWT is refreshed on 401 and proactively
  near 20h, so an 11k-issue run that spans a day doesn't die mid-import.
- **Gherkin read from the correct field** — raven returns Cucumber/Generic bodies
  under `definition` (not `scenario`); branched by test kind so scenarios aren't lost.
- **`ABORTED` preserved** (it's a native Cloud status, not downgraded to FAILED).
- **Per-step attachments bound to the step**, defects in other projects kept,
  run assignee carried, data-driven iterations and Test Environments captured,
  comments imported as rendered text (not raw wiki) with visibility preserved,
  non-idempotent creates not blindly retried (no duplicates), binary downloads
  size-verified, and per-item (not per-issue) resumability.

---

## ⚠️ Rotate your credentials

Several files in the parent folders hold **live secrets in plaintext** (Jira API
token, Xray Client Id/Secret, server passwords). After the migration, revoke and
regenerate:
- Jira Cloud API token → https://id.atlassian.com/manage-profile/security/api-tokens
- Xray Cloud Client Id/Secret → Jira Cloud → Apps → Xray → **API Keys**
- Change the Jira **Server** account password if it was committed anywhere.

These scripts never hardcode secrets — they read them from environment variables
or prompt securely.

---

## Prerequisites

1. **PowerShell 5.1 (Windows) or 7+.** No extra modules.
2. **Xray Cloud installed on the target project `TEST`**, with the issue types
   `Test`, `Precondition`, `Test Set`, `Test Plan`, `Test Execution`,
   `Sub Test Execution` on its scheme. (Phase 0 verifies this.)
3. **Xray Cloud API Key** (Client Id + Secret): Jira Cloud → Apps → Xray → API Keys.
4. **Jira Cloud API token** for your account.
5. A **Jira Server** account that can read `MFTBCTRKD` and its Xray data.
6. *(Recommended)* migrate the **non-Xray issues first** (Stories/Defects, via
   JCMA) so issue **links** and **Sub Test Execution parents** resolve.

---

## Credentials (env vars — optional but recommended)

```powershell
# Source (Jira Server)
$env:XRAY_SRV_USER      = "your.server.username"
$env:XRAY_SRV_PASS      = "your.server.password"
# Target (Jira Cloud)
$env:JIRA_CLOUD_EMAIL   = "you@example.com"
$env:JIRA_CLOUD_TOKEN   = "<jira-cloud-api-token>"
# Target (Xray Cloud)
$env:XRAY_CLIENT_ID     = "<xray-client-id>"
$env:XRAY_CLIENT_SECRET = "<xray-client-secret>"
```

Anything unset is prompted for securely.

---

## Step-by-step

### 0. First time only — unblock the scripts

```powershell
cd "<this Final folder>"
Get-ChildItem *.ps1 | Unblock-File
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

### 1. Edit `config.ps1`
Confirm `JiraServerUrl`, `CloudProjectKey = "TEST"`, `XrayCloudBase` (use a
regional host if your site has data residency).

### 2. Preflight (read-only go/no-go)
```powershell
.\Run-Migration.ps1 -Only Preflight
# or:  .\Phase0_Preflight.ps1
```
Must end with **GO**. If it says the Xray types are missing on `TEST`, install/enable
Xray there first — that is exactly what caused the old `Specify a valid issue type` errors.
It also writes `export\MFTBCTRKD\_source_counts.csv` (your reconciliation baseline).

### 3. Dry run (5 issues per type, end to end)
```powershell
.\Run-Migration.ps1 -DryRun
```
Open a migrated **Test** in Cloud and confirm its type + steps; a **Test Set** lists
its tests; a **Test Execution** shows imported results.

### 4. Full export
```powershell
.\Phase1_Export_Server.ps1
```
Resumable — re-running skips issues already written. Output:
```
export\MFTBCTRKD\
  issues\<IssueType>\<KEY>.json     full record per issue
  attachments\<KEY>\...             issue attachments
  xray\steps\<KEY>\stepN\...        manual-step attachments
  xray\evidence\<TE>\<T>\...        run + step evidence
  features\<KEY>.zip                Cucumber .feature exports
  _index.csv  _fields.csv  _manifest_*.csv  _export.log
```
> This export directory **is your full backup.** Even data the import cannot
> perfectly reconstruct (original authors/dates, custom-field internals) is
> preserved here verbatim.

### 5. (Optional) user mapping for run authorship
Cloud needs **accountId**, not username, to preserve "executed by"/assignee/reporter:
```powershell
.\Phase2_Import_Cloud.ps1 -Steps usermap
# Fill CloudAccountId in export\MFTBCTRKD\_user_map_template.csv,
# save it as export\MFTBCTRKD\_user_map.csv, then run results/fields.
```
Find accountIds via `GET /rest/api/3/user/search?query=<email>`.

### 6. Full import
```powershell
.\Phase2_Import_Cloud.ps1
```
Default steps (all resumable):

| Step | What it does | API |
|---|---|---|
| `issues` | Creates every issue; Tests via `createTest` (type+steps+gherkin/generic+step attachments+preconditions+folder); Preconditions via `createPrecondition`. Builds `_key_map.csv`. | Jira REST + Xray GraphQL |
| `associations` | Test Set→tests, Test Plan→tests+executions, Test Execution→tests. | Xray GraphQL |
| `attachments` | Re-uploads issue attachments. | Jira REST |
| `comments` | Re-creates comments (author/date/visibility preserved). | Jira REST |
| `links` | Re-creates issue links where both ends migrated. | Jira REST |
| `results` | Imports run results (status, comment, evidence, defects, step results, test environments). | Xray import |

Optional extra steps:
```powershell
.\Phase2_Import_Cloud.ps1 -Steps fields      # promote priority/components/versions/dates/people to NATIVE fields
.\Phase2_Import_Cloud.ps1 -Steps worklogs    # re-create worklogs
.\Phase2_Import_Cloud.ps1 -Steps results     # re-run just one step
```

### 7. Reconcile
Compare against `_source_counts.csv` (your known totals): Pre-Condition 100,
Test 7186, Test Set 202, Test Execution 437, Test Plan 18, Sub Test Execution 3011.
Use `_import_errors.log` to find failures and re-run the affected step (re-running
only retries what failed).

---

## No-data-loss coverage matrix

| Data | Exported (Phase 1) | Imported (Phase 2) | Method / note |
|---|:--:|:--:|---|
| Summary, description, labels | ✅ | ✅ | REST v3 create, description as ADF |
| Test type (Manual/Cucumber/Generic) | ✅ | ✅ | GraphQL `createTest` |
| Manual steps (action/data/result) | ✅ | ✅ | `createTest` steps |
| Manual-step attachments | ✅ | ✅ | bound to the step via `CreateStepInput.attachments` |
| Gherkin scenario | ✅ | ✅ | raven `definition` + `.feature` fallback |
| Generic/unstructured definition | ✅ | ✅ | `createTest` unstructured |
| Test repository / folder path | ✅ | ✅ | `createTest` folderPath |
| Preconditions + definition + type | ✅ | ✅ | `createPrecondition` + `preconditionIssueIds` |
| Test Set / Plan / Execution memberships | ✅ | ✅ | GraphQL add* mutations |
| Run status / comment / dates | ✅ | ✅ | `import/execution` (incl. ABORTED) |
| Run evidence + step evidence | ✅ | ✅ | base64 in `import/execution` |
| Run + step defects | ✅ | ✅ | original keys kept even if cross-project |
| Step results (status/comment/actualResult) | ✅ | ✅ | `import/execution` steps |
| executedBy / assignee | ✅ | ⚠️ | set as accountId **if** mapped; else noted in comment |
| Test Environments | ✅ | ✅ | `import/execution` info.testEnvironments |
| Data-driven iterations / examples | ✅ | ⚠️ | exported raw + sent best-effort (datasets aren't fully API-reachable) |
| Comments (author/date/visibility) | ✅ | ⚠️ | re-created; author/date noted in text (Cloud can't backdate); visibility preserved |
| Attachments | ✅ | ✅ | multipart upload |
| Issue links | ✅ | ✅ | when both ends migrated + type exists |
| Worklogs | ✅ | ⚠️ | optional `worklogs` step; author noted in text |
| Priority/components/versions/duedate/env/people | ✅ | ⚠️ | description metadata block by default; optional `fields` step promotes to native |
| All custom fields | ✅ | ⚠️ | preserved in description block + full fidelity in export JSON |
| Change history (changelog) | ✅ (backup) | ❌ | Jira REST cannot write historical events |

✅ migrated · ⚠️ migrated with a documented caveat · ❌ kept in the backup only

---

## Status mapping (Server → Cloud)

| Server | Cloud |
|---|---|
| PASS | PASSED |
| FAIL | FAILED |
| ABORTED | ABORTED *(native on Cloud)* |
| TODO / EXECUTING | (same) |
| *custom statuses* | passed through — **must already exist in Cloud** |

For a custom Server status, create it in Xray Cloud first, or add a mapping in
`$statusOverrides` near the top of `Phase2_Import_Cloud.ps1`.

---

## Known limitations (and mitigations)

- **Original authors & timestamps** of issues/comments/attachments/runs cannot be
  set via Cloud REST — attributed to the importing user; originals are preserved
  in the export JSON and echoed into comment/run text.
- **Change history** is captured for reference but cannot be recreated in Cloud.
- **Data-driven datasets** aren't exposed by any Xray Server GET; iteration
  *results* are exported raw and sent best-effort, but the dataset itself may need
  the Xray dataset CSV import.
- **Sub Test Executions** are sub-tasks; if the parent wasn't migrated they become
  standalone Test Executions labelled `migrated-sub-test-execution`
  (`-SubExecFallback Skip` to skip instead). Migrate parents first to avoid this.
- **Custom fields / components / versions** aren't set natively by default (target
  schemes differ; setting unknown values would 400). They're preserved in the
  description block; run `-Steps fields` to promote the safe ones best-effort.

---

## Troubleshooting

| Symptom | Cause / Fix |
|---|---|
| Preflight: Xray types MISSING on `TEST` | Install/enable Xray Cloud on the project and add the 6 types to its issue-type scheme. |
| HTTP 400 `Specify a valid issue type` | Same as above; the importer aborts the `issues` step until types exist. |
| HTTP 400 `must be an Atlassian Document` | Stale script — this toolkit always sends ADF. Ensure you're running these files. |
| TLS/SSL trust error on export | Keep `AllowInsecureSource = $true` (it's scoped to the source host only). |
| HTTP 401 from Xray Cloud mid-run | Token auto-refreshes; if it persists, re-run the step (resumable). |
| HTTP 429 | Throttle + Retry-After back off automatically; raise `XrayThrottleMs`/`CloudThrottleMs` if persistent. |
| `Xray data is in another region` | Set `XrayCloudBase` to the regional host (`us`/`eu`/`au`). |
| Duplicate issues after a crash | Re-runs adopt existing `srvkey-<KEY>`-labelled issues; creates aren't blindly retried on 5xx. |
| `createTest` warnings in log | Usually a non-fatal ignored field; the test is still created. |
