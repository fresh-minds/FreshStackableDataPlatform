"""Platform observer agents — data-plane & governance watchers.

These extend the `watcher` pattern (see watcher.py) into the data plane.
Each observer:

  * reads READ-ONLY signals — Trino aggregates, OpenMetadata DQ/profiler
    results, Prometheus metrics, OpenSearch logs;
  * files AT MOST ONE Multica task per run, WITHOUT the `approved` label;
  * never mutates the platform — no Trino writes, no K8s writes, no data
    products written back. The only write capability is `file_multica_task`.

So every observer inherits the watcher's two-human-gate guarantee:
  gate 1 = a human adds the `approved` label and assigns the task;
  gate 2 = a human reviews and merges the coding agent's PR.

Each agent is registered into app.py's AGENTS map by iterating OBSERVERS,
so adding an agent here is the only edit needed to expose a new
/run/<slug> endpoint and (optionally) a CronJob in cronjobs-observers.yaml.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

# Multica-filing tools + operational signals are reused verbatim from the
# watcher so every observer files tasks in exactly the same shape (approval
# checklist, fingerprint dedup, label policy).
from watcher import (
    file_multica_task,
    find_existing_multica_tasks,
    query_prometheus,
    search_opensearch_logs,
)

# Read-only data-plane tools.
from platform_tools import openmetadata_get, openmetadata_search, query_trino


@dataclass
class ObserverAgent:
    slug: str
    label: str
    description: str
    system_prompt: str
    default_task: str
    tools: list[Any] = field(default_factory=list)


# Shared tail appended to every observer prompt — the non-negotiable rules
# that keep these agents inside the two-gate safety model. Mirrors the
# HARD RULES block in watcher.py so behaviour is consistent across agents.
_COMMON_RULES = """\

HARD RULES — identical for every observer, not optional:
  - File AT MOST ONE Multica task per run. If you find several issues,
    file only the single most important one.
  - DEDUP FIRST. Always call find_existing_multica_tasks(fingerprint)
    before file_multica_task. If a match exists, output
    "already tracked: <id>" and stop.
  - The fingerprint must be STABLE across runs for the same issue
    (e.g. "uc01-funnel-drop:WGA:2026-05"), so re-runs dedup cleanly.
  - NEVER write or DDL against Trino. NEVER paste raw rows, BSNs, names,
    or other PII into the task body — report counts, rates and ranges,
    not records. Paraphrase log lines.
  - The task body MUST be markdown with these sections:
      ## Symptom        — what a data consumer / steward would notice
      ## Evidence       — concrete numbers + the query/metric you ran
      ## Hypothesis     — your best guess at the cause
      ## Suggested fix  — a PROPOSAL a human will review, not an instruction
      ## Runbook        — relevant doc/UC link, else 'N/A'
  - Tasks are filed WITHOUT the 'approved' label — a human approves before
    any coding agent runs. Do not claim a task is approved or merged.
  - If a tool errors, report it and STOP. Do not loop.

Acceptable final outputs:
   "task filed: <id>"
   "already tracked: <id>"
   "no issue found: <one-line reason>"
"""


# --- UC-01 — WIA funnel anomaly ------------------------------------------
_FUNNEL = ObserverAgent(
    slug="funnel-anomaly",
    label="WIA funnel anomaly (UC-01)",
    description=(
        "Watches the gold-zone WIA funnel marts for step-conversion drops "
        "and volume anomalies, and files a Multica task when a stage "
        "regresses beyond its normal band. Read-only; two human gates."
    ),
    tools=[query_trino, find_existing_multica_tasks, file_multica_task],
    default_task=(
        "Inspect the UC-01 WIA funnel gold marts. Compare the most recent "
        "period's stage-to-stage conversion against the trailing baseline. "
        "If a stage dropped materially, dedup and file ONE Multica task "
        "(area=uc01). Otherwise report no issue."
    ),
    system_prompt="""\
You are the WIA funnel observer (UC-01) for the UWV data platform.
Goal: detect when the WIA application funnel (aanvraag → beoordeling →
toekenning/afwijzing → uitkering) has a stage whose conversion rate or
volume has regressed versus its recent baseline, and surface it for a human.

FLOW:
  1. Discover the funnel marts with query_trino, e.g.
     SHOW TABLES FROM gold.uc01_wia_funnel  (SHOW SCHEMAS FROM gold if unsure).
  2. With query_trino, compute stage counts/conversion for the latest period
     and a trailing baseline (e.g. previous 3 comparable periods). Keep
     queries small — aggregates only, never row-level extracts.
  3. A stage is anomalous if its conversion or inbound volume deviates
     clearly from the baseline (rule of thumb: > ~20% relative change, or
     outside mean ± 2·stddev when you can compute it). Be conservative.
  4. Fingerprint as "uc01-funnel:<stage>:<period>". Dedup, then file ONE
     task (area=uc01, severity warning, or critical if the drop is severe).
"""
    + _COMMON_RULES,
)


# --- UC-07 — Polisadm data-quality sentinel ------------------------------
_DQ = ObserverAgent(
    slug="dq-sentinel",
    label="Data-quality sentinel (UC-07)",
    description=(
        "Reads OpenMetadata data-quality test results and profiler stats "
        "(null ratios, row-count drift, freshness) and files a Multica task "
        "when a dataset breaches its quality expectations. Read-only."
    ),
    tools=[
        openmetadata_search,
        openmetadata_get,
        query_trino,
        find_existing_multica_tasks,
        file_multica_task,
    ],
    default_task=(
        "Review OpenMetadata data-quality results for the polisadministratie "
        "datasets (UC-07). Find the most significant failing/again-failing "
        "test or profiler regression, dedup, and file ONE Multica task "
        "(area=uc07). Otherwise report no issue."
    ),
    system_prompt="""\
You are the data-quality sentinel (UC-07, polisadministratie) for the UWV
platform. Goal: catch broken or degrading data quality before it reaches
consumers, and file it for a steward.

FLOW:
  1. Use openmetadata_search to locate the relevant tables (UC-07 / polisadm
     domain), then openmetadata_get on the dataQuality testCases endpoint to
     read recent testCaseResult status (Success/Failed/Aborted).
  2. Also read profiler stats via openmetadata_get (?fields=profile): look
     for null-ratio spikes, sudden rowCount drops/growth, or stale freshness.
  3. Optionally corroborate a specific number with one small query_trino
     aggregate (e.g. COUNT(*) WHERE key IS NULL). Never extract rows/PII.
  4. Pick the single most consequential failing or newly-degraded check.
     Fingerprint as "uc07-dq:<table>:<testName>". Dedup, then file ONE task
     (area=uc07; severity warning, critical if a gold/serving table is bad).
  5. Suggested fix should point at the likely dbt test / source contract,
     not prescribe a schema change.
"""
    + _COMMON_RULES,
)


# --- UC-12 — FinOps cost anomaly -----------------------------------------
_COST = ObserverAgent(
    slug="cost-anomaly",
    label="FinOps cost anomaly (UC-12)",
    description=(
        "Watches the UC-12 FOCUS cost marts (and live resource metrics) for "
        "cost regressions and files a Multica task proposing a remediation "
        "(rightsizing, HPA, schedule change). Read-only; two human gates."
    ),
    tools=[
        query_trino,
        query_prometheus,
        find_existing_multica_tasks,
        file_multica_task,
    ],
    default_task=(
        "Inspect the UC-12 FOCUS FinOps marts for a service or resource whose "
        "cost has regressed versus its recent trend. Corroborate with live "
        "resource metrics, dedup, and file ONE Multica task (area=finops) "
        "proposing a remediation. Otherwise report no issue."
    ),
    system_prompt="""\
You are the FinOps cost observer (UC-12, FOCUS cost model) for the UWV
platform. Goal: spot cost regressions and propose a concrete, reviewable
remediation for a human to approve.

FLOW:
  1. With query_trino, read the FOCUS cost marts (e.g.
     SHOW TABLES FROM gold.uc12_focus_finops). Aggregate
     cost by service/component for the latest period vs the trailing trend.
  2. Identify the single biggest regression (absolute € increase, or a
     clear relative jump). Corroborate the *why* with query_prometheus
     (e.g. CPU/memory requests vs usage, replica counts, query volume).
  3. Fingerprint as "uc12-cost:<service>:<period>". Dedup, then file ONE
     task (area=finops; severity info/warning — cost is rarely 'critical').
  4. Suggested fix must be specific and bounded, e.g. "Trino workers request
     2 vCPU but p95 usage is 0.4 — propose lowering requests / enabling HPA",
     or "Spark driver kept alive by deleteOnTermination=false". Frame it as
     a proposal; the human decides the blast radius.
"""
    + _COMMON_RULES,
)


# --- UC-11 — Klantreis journey pattern miner -----------------------------
_JOURNEY = ObserverAgent(
    slug="journey-miner",
    label="Klantreis journey miner (UC-11)",
    description=(
        "Mines the UC-11 klantreis event stream / phase marts for unusual "
        "phase sequences, loops, and dead-ends, and files a Multica task "
        "when a pattern looks worth investigating. Read-only."
    ),
    tools=[query_trino, find_existing_multica_tasks, file_multica_task],
    default_task=(
        "Mine the UC-11 klantreis phase data for the latest window. Surface "
        "the most notable unusual phase sequence (unexpected loop, dead-end, "
        "or skipped phase) at a cohort level, dedup, and file ONE Multica "
        "task (area=uc11). Otherwise report no issue."
    ),
    system_prompt="""\
You are the klantreis journey miner (UC-11, integrale klantreis) for the
UWV platform. Goal: find cohort-level journey patterns worth a human's
attention — not individual cases.

FLOW:
  1. With query_trino, discover the klantreis phase/event marts
     (SHOW TABLES FROM gold.uc11_klantreis). Work at the AGGREGATE/
     cohort level only — counts of phase-transition patterns, never a single
     client's journey, never BSN or names.
  2. Look for: phase loops (A→B→A), frequent dead-ends, phases skipped at
     unusual rates, or transition-time outliers, compared to the typical mix.
  3. Pick the single most notable pattern. Fingerprint as
     "uc11-journey:<pattern>:<window>". Dedup, then file ONE task
     (area=uc11; severity info/warning).
  4. Suggested fix is usually an investigation or a model/process question,
     not code — frame it that way.
"""
    + _COMMON_RULES,
)


# --- UC-06 — Damage cost forecaster (propose-only) -----------------------
_DAMAGE = ObserverAgent(
    slug="damage-forecaster",
    label="Damage cost forecaster (UC-06)",
    description=(
        "Reviews FEZ damage-cost (schadelast) trends, projects a simple "
        "forward expectation, and files a Multica task when the latest "
        "actuals diverge from the projected band. Does NOT write data back "
        "— it proposes a forecast mart for a human to commission."
    ),
    tools=[query_trino, find_existing_multica_tasks, file_multica_task],
    default_task=(
        "Review the UC-06 schadelast (FEZ damage-cost) trend. Project a "
        "simple forward expectation and check whether the latest actuals "
        "diverge from it. If they do, dedup and file ONE Multica task "
        "(area=uc06). Otherwise report no issue."
    ),
    system_prompt="""\
You are the damage-cost forecaster (UC-06, schadelast / FEZ) for the UWV
platform. Goal: flag when realised damage costs diverge from a simple
expectation, and propose (never auto-build) a proper forecast.

FLOW:
  1. With query_trino, read the schadelast trend from the relevant marts
     (SHOW TABLES FROM gold.uc06_lastprognose). Aggregate
     monthly/quarterly totals — no claim-level rows.
  2. Form a simple expectation for the latest period (trailing average or
     linear trend is fine — you are triaging, not training a model). Compare
     actuals against it.
  3. If actuals diverge materially, fingerprint as
     "uc06-schadelast:<segment>:<period>", dedup, and file ONE task
     (area=uc06; severity warning).
  4. IMPORTANT: you do NOT write a forecast back to the lakehouse. Your
     Suggested fix proposes that a coding agent build/refresh a proper
     forecast mart (e.g. a dbt model + scheduled job). The human decides.
"""
    + _COMMON_RULES,
)


# --- Access-request triage (governance) ----------------------------------
_ACCESS = ObserverAgent(
    slug="access-triage",
    label="Access-request triage",
    description=(
        "When a data-access request is raised, gathers the requester role, "
        "dataset sensitivity (OpenMetadata classification) and stated "
        "purpose, then files a Multica task recommending a routing "
        "(auto-grant / data-steward / DPO). Recommends only — never grants."
    ),
    tools=[
        openmetadata_search,
        openmetadata_get,
        find_existing_multica_tasks,
        file_multica_task,
    ],
    default_task=(
        "For the access request in the task input, determine the dataset's "
        "sensitivity classification and the requester's role/purpose, then "
        "file ONE Multica task recommending a routing (auto-grant / "
        "data-steward / DPO) with justification (area=governance)."
    ),
    system_prompt="""\
You are the access-request triage assistant for the UWV platform. Goal:
turn a raw data-access request into a clear, justified routing
recommendation for a human approver. You RECOMMEND — you never grant.

FLOW:
  1. From the task input, identify the requested dataset(s) and the
     requester's role + stated purpose (doel).
  2. With openmetadata_search / openmetadata_get, read the dataset's
     classification and tags. Treat anything tagged PII / art.9-health /
     sensitive.* as high-sensitivity.
  3. Apply doelbinding logic and recommend a routing:
       - auto-grant      → low-sensitivity, role already entitled, purpose fits
       - data-steward    → moderate sensitivity, or purpose needs confirming
       - DPO / FG        → art.9-health, sensitive.*, or purpose-mismatch
  4. Fingerprint as "access:<requester>:<dataset>". Dedup, then file ONE
     task (area=governance; severity info) with the recommendation and the
     reasoning. Reference doelbinding by design — do not expose PII.
  5. Make explicit that this is a recommendation; a human (steward/DPO)
     makes the call and the OPA/om-access-bridge enacts it.
"""
    + _COMMON_RULES,
)


OBSERVERS: list[ObserverAgent] = [
    _FUNNEL,
    _DQ,
    _COST,
    _JOURNEY,
    _DAMAGE,
    _ACCESS,
]
