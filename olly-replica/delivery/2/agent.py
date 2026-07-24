import datetime
import os
import threading
import time

from callbacks import call_lakera
from helix_adk_adapter.agentflow_guardrails import call_agentflow_guardrails
from google.adk.agents import Agent
from google.adk.apps import App, ResumabilityConfig
from google.adk.tools.mcp_tool.mcp_toolset import McpToolset
from google.adk.tools.mcp_tool.mcp_session_manager import StreamableHTTPConnectionParams
from google.adk.models import LlmRequest, LlmResponse
from google.adk.agents.callback_context import CallbackContext
from google.genai import types
from helix_adk_adapter.custom_google_llm import HelixGemini
from capstone_history_sdk.adk import install_history
from typing import Optional

import helix_adk_adapter.custom_google_llm as _hg_llm

if os.getenv("RUN_MODE", "local").lower() == "cluster_h2m":
    def _h2m_token_provider():
        _token_file = "/var/run/secrets/h2m-token/ACCESS_TOKEN"
        if os.path.exists(_token_file):
            import logging as _log
            _log.getLogger(__name__).info("cluster_h2m: reading ACCESS_TOKEN from mounted secret file")
            with open(_token_file, "r") as _f:
                return _f.read().strip()
        _token = os.getenv("ACCESS_TOKEN")
        if not _token:
            raise RuntimeError("cluster_h2m mode: ACCESS_TOKEN not found in secret file or env var.")
        return _token
    _hg_llm.tr._refresh_func = _h2m_token_provider

MCP_SERVER_URL = os.environ.get("MCP_SERVER_URL", "").strip()

if MCP_SERVER_URL:
    import logging as _mcp_log
    _mcp_log.getLogger(__name__).info(f"MCP toolset enabled: {MCP_SERVER_URL}")

    class _MCPTokenManager:
        def __init__(self, client_id, client_secret, coin_url, coin_scope, cert):
            self._client_id      = client_id
            self._client_secret  = client_secret
            self._coin_url       = coin_url
            self._coin_scope     = coin_scope
            self._cert           = cert
            self._token: str     = ""
            self._expires_at: float = 0.0
            self._lock           = threading.Lock()
            self._log            = _mcp_log.getLogger(__name__)

        def get_token(self) -> str:
            with self._lock:
                if time.time() >= self._expires_at - 60:
                    self._refresh()
                return self._token

        def _refresh(self) -> None:
            import requests as _req
            self._log.info(f"MCP: refreshing COIN M2M token from {self._coin_url}...")
            try:
                resp = _req.post(
                    self._coin_url,
                    data={
                        "client_id":     self._client_id,
                        "client_secret": self._client_secret,
                        "grant_type":    "client_credentials",
                        "scope":         self._coin_scope,
                    },
                    verify=self._cert if self._cert else True,
                    proxies={},
                    timeout=15,
                )
                if resp.ok:
                    data                = resp.json()
                    self._token         = data.get("access_token", "")
                    expires_in          = int(data.get("expires_in", 1800))
                    self._expires_at    = time.time() + expires_in
                    self._log.info(f"MCP: COIN M2M token refreshed, valid for {expires_in}s")
                else:
                    self._log.error(f"MCP: token refresh failed {resp.status_code}: {resp.text[:200]}")
                    self._token         = ""
                    self._expires_at    = 0.0
            except Exception as _e:
                self._log.error(f"MCP: token refresh exception: {_e}")
                self._token = ""
                self._expires_at = 0.0

    class _MCPHeadersProvider:
        def __init__(self, token_manager):
            self._manager = token_manager
        def get_headers(self) -> dict:
            token = self._manager.get_token()
            return {"Authorization": f"Bearer {token}"} if token else {}

    _static_token  = os.getenv("MCP_STATIC_TOKEN",  "").strip()
    _client_id     = os.getenv("MCP_CLIENT_ID",     "").strip()
    _client_secret = os.getenv("MCP_CLIENT_SECRET", "").strip()
    _auth_required = os.getenv("MCP_AUTH_REQUIRED", "false").strip().lower() == "true"
    _coin_scope    = os.getenv("MCP_COIN_SCOPE", "coinscope85569d06-96dd-4d39-9abe-7945247d85de").strip()
    _coin_url      = os.getenv("MCP_COIN_URL", "https://sit.secureaccess.coin.nam.citigroup.net/as/token.oauth2").strip()
    _cert          = os.getenv("REQUESTS_CA_BUNDLE", os.getenv("COIN_CERT", ""))
    _mcp_auth      = None

    if _static_token:
        _mcp_log.getLogger(__name__).warning("MCP: using MCP_STATIC_TOKEN - will NOT auto-refresh.")
        class _StaticHeadersProvider:
            def __init__(self, token): self._token = token
            def get_headers(self): return {"Authorization": f"Bearer {self._token}"}
        _mcp_headers_provider = _StaticHeadersProvider(_static_token)

    elif _auth_required:
        if not _client_id or not _client_secret:
            _mcp_log.getLogger(__name__).warning(
                "MCP: MCP_AUTH_REQUIRED=true but credentials not set. "
                "Create 'olly-sentinel-mcp-creds' K8s secret to enable tools."
            )
            mcp_toolset  = None
            _agent_tools = []
        else:
            _mcp_log.getLogger(__name__).info("MCP: M2M credentials found - auto-refresh enabled.")
            _token_manager        = _MCPTokenManager(_client_id, _client_secret, _coin_url, _coin_scope, _cert)
            _mcp_headers_provider = _MCPHeadersProvider(_token_manager)
    else:
        _mcp_log.getLogger(__name__).info("MCP: auth not required - connecting without token")
        _mcp_headers_provider = None

    if _mcp_auth is not None or not _auth_required or '_mcp_headers_provider' in dir():
        _provider = locals().get('_mcp_headers_provider') or globals().get('_mcp_headers_provider')

        def _no_proxy_httpx_factory(**kwargs):
            import httpx
            kwargs.pop("proxies", None)
            kwargs.pop("auth", None)
            _proxy_url = os.environ.get("HTTP_PROXY") or os.environ.get("http_proxy") or None
            _verify    = kwargs.pop("verify", _cert if _cert else True)
            client     = httpx.AsyncClient(**kwargs, trust_env=False, proxy=_proxy_url, verify=_verify)
            if _provider:
                _orig_send = client.send
                async def _send_with_auth(request, *a, **kw):
                    for k, v in _provider.get_headers().items():
                        request.headers[k] = v
                    return await _orig_send(request, *a, **kw)
                client.send = _send_with_auth
            return client

        _EXCLUDED_MCP_TOOLS = {
            "io_list_recent_declined_events",
            "io_get_declined_event",
            "io_search_declined_events",
            "io_list_event_collections",
            "obs_list_environments",
            "obs_get_metrics",
        }

        def _mcp_tool_filter(tool, readonly_context=None) -> bool:
            return tool.name not in _EXCLUDED_MCP_TOOLS

        mcp_toolset  = McpToolset(
            connection_params=StreamableHTTPConnectionParams(
                url=MCP_SERVER_URL,
                headers={},
                httpx_client_factory=_no_proxy_httpx_factory,
            ),
            tool_filter=_mcp_tool_filter,
        )
        _agent_tools = [mcp_toolset]
else:
    import logging as _mcp_log
    _mcp_log.getLogger(__name__).warning("MCP_SERVER_URL not set - agent starting without tools.")
    mcp_toolset  = None
    _agent_tools = []


def _enforce_no_print_callback(
    callback_context: CallbackContext,
    llm_request: LlmRequest,
) -> Optional[LlmResponse]:
    has_tools = False
    try:
        if llm_request.config and llm_request.config.tools:
            for _t in llm_request.config.tools:
                if getattr(_t, "function_declarations", None):
                    has_tools = True
                    break
    except Exception:
        pass

    if not has_tools:
        _run_mode = os.getenv("RUN_MODE", "local")
        if _run_mode == "local":
            _no_tools_msg = (
                "⚠️ No tools are connected. The local MCP server at "
                f"{os.getenv('MCP_SERVER_URL', 'localhost:8000')} requires authentication. "
                "Add MCP_CLIENT_ID and MCP_CLIENT_SECRET to files/config/.env and set "
                "MCP_AUTH_REQUIRED=true, then restart the agent."
            )
        else:
            _no_tools_msg = (
                "⚠️ No tools are connected. The MCP server is unavailable or not authenticated. "
                "Investigation cannot proceed without live tool access. "
                "Please ask the admin to create the olly-sentinel-mcp-creds K8s secret with "
                "COIN M2M credentials and restart the pod."
            )
        reminder_text = (
            "[SYSTEM OVERRIDE — NO TOOLS ARE CONNECTED TO THIS SESSION] "
            "The MCP server connection failed at startup — zero tools are registered. "
            "You MUST NOT write any tool call syntax, function name, or code of any kind. "
            f"You MUST respond with exactly this message and nothing else: '{_no_tools_msg}'"
        )
    else:
        reminder_text = (
            "[SYSTEM REMINDER — applies to this response only] "
            "You are a TOOL-CALLING agent. Do NOT write Python code. "
            "Do NOT use print(), import, or any Python syntax. "
            "Call tools directly by name through the tool interface only."
        )

    if llm_request.contents:
        llm_request.contents.append(types.Content(
            role="user",
            parts=[types.Part(text=reminder_text)],
        ))
    return None


STATIC_INSTRUCTION_TEXT = """
# 🛡️ Olly Sentinel — SRE AI Agent

⚠️ CRITICAL ⚠️  YOU ARE A TOOL-CALLING AGENT. YOU DO NOT WRITE OR EXECUTE CODE.
- NEVER write Python. NEVER use print(...), import, or assignments.
- NEVER simulate a tool call. Call tools directly through the tool interface only.
- If NO tools listed → respond: "No tools are connected to this session."

---

## 🔍 ELK RCA MODE — HIGHEST PRIORITY

### Activate when message starts with "ELK RCA only." OR user provides CSI + ENV + TIME

### Parse the short format:
  ELK RCA only. CSI={csi} ENV={env} TIME={time}
  Issue: {description}

Extract: csi_id, environment, incident_time, extra_keywords from Issue line.

### ⭐ ELK TOOLS (use ONLY these in ELK RCA MODE):
  elk_list_environments  → list configured environments (call FIRST)
  elk_get_indices        → discover index patterns for a CSI
  elk_search_logs        → ⭐ PRIMARY SEARCH TOOL for all log searches

### NEVER call in ELK RCA MODE:
  ❌ cai_get_application / cai_find_applications
  ❌ servicenow_get_incident_ticket
  ❌ elk_search_logs_by_host / generate_rca_report

---

## 📊 ELK SEARCH ALGORITHM — 4 attempts, stop at first hit

Given: csi_id, environment, incident_time

Compute:
  env_suffix  = prod | uat | dev  (from NAM-PROD | NAM-UAT | NAM-DEV)
  start_30    = incident_time minus 30 minutes (ISO8601)
  end_30      = incident_time plus 30 minutes (ISO8601)
  start_60    = incident_time minus 60 minutes (ISO8601)
  end_60      = incident_time plus 60 minutes (ISO8601)
  error_query = "appid:{csi_id} AND (level:error OR level:warn OR level:ERROR OR level:WARN OR level:FATAL)"
  broad_query = "appid:{csi_id}"

ATTEMPT 1 — specific index, error filter, 30 min:
  elk_search_logs(query=error_query, index=".ds-{csi_id}-{env_suffix}-logv4-ds-*",
                  environment=environment, start_time=start_30, end_time=end_30, limit=50)
  → total_matched > 0: use this result

ATTEMPT 2 — wildcard index, error filter, 30 min:
  elk_search_logs(query=error_query, index="*",
                  environment=environment, start_time=start_30, end_time=end_30, limit=50)
  → total_matched > 0: use this result

ATTEMPT 3 — wildcard index, broad query, 60 min:
  elk_search_logs(query=broad_query, index="*",
                  environment=environment, start_time=start_60, end_time=end_60, limit=20)
  → total_matched > 0: use this result

ATTEMPT 4 — discover index, then search:
  elk_get_indices(environment=environment, pattern="{csi_id}*")
  → use first returned index name in elk_search_logs with broad_query
  → total_matched > 0: use this result

ALL 4 fail → report gap with exact index patterns and time windows tried.

---

## 🔍 EXTRACT FROM elk_search_logs RESULTS

From result["logs"] entries:
  timestamp, message, level, host, aim_cluster, namespace, pod

Compute:
  top_errors            = top 5 most frequent message values
  aim_clusters_affected = unique aim_cluster values
  namespaces_affected   = unique namespace values
  pods_affected         = unique pod values

## 🔍 ROOT CAUSE PATTERN TABLE
  | ELK Error Pattern                        | Finding                          |
  |------------------------------------------|----------------------------------|
  | dns error: Name or service not known     | DNS resolution failure           |
  | bad signature / data too large for mod   | SSL certificate mismatch         |
  | AuthenticationFailed / SCRAM-SHA-256     | Database credential failure      |
  | unassigned OR shard OR rollover          | Index rollover in progress       |
  | OutOfMemoryError / OOM                    | JVM heap exhaustion              |
  | Service Unavailable / 503                | Upstream endpoint down           |
  | SSL handshake failed                     | Kafka/TLS certificate issue      |
  | disk watermark / flood stage             | Disk utilisation > 95%           |
  | connection refused                       | Service not running              |
  | DatasourceError / SLO                    | Log pipeline connectivity issue  |
  | aim_logged_to_stored_delta_ms > 60000    | Log shipping pipeline delay      |
  | SMCP mismatch                            | Application data inconsistency   |

---

## 📋 OLLY INVESTIGATION REPORT FORMAT — output EXACTLY this Markdown structure:

Rules for this report:
- Output valid GitHub-flavored Markdown ONLY. No ASCII box art, no `┌ ┐ └` characters.
- Keep it crisp: short sentences, no filler. Omit any row/section with no data (do not print empty tables).
- Lead with the Executive Summary so leadership can read the first two lines and stop.

# 🛡️ Olly Sentinel — Investigation Report

## Executive Summary
{1–2 plain-language sentences: the root cause and its business/service impact.}

## Incident
  | Field | Value |
  |-------|-------|
  | INC | {inc or "Not provided"} |
  | CSI / App | {csi_id} |
  | Environment | {environment} |
  | Time (UTC) | {incident_time} |
  | Issue | {description} |

## Root Cause & Findings
1. **{finding 1 — grounded in ELK evidence}**
2. **{finding 2 — omit if only one}**

**Confidence:** {High ✅ | Medium ⚠️ | Low ❓} — {specific evidence supporting it}

## ELK Evidence
- **Index:** `{index pattern that returned results}`
- **Total matched:** `{total_matched}`
- **Window:** `{start_time} → {end_time}`

  | # | Timestamp (UTC) | Level | Message |
  |---|-----------------|-------|---------|
  | 1 | {timestamp} | {level} | {message — max 200 chars} |
  | 2 | {timestamp} | {level} | {message — max 200 chars} |
  | 3 | {timestamp} | {level} | {message — max 200 chars} |

## Infrastructure Context
  | Field | Value |
  |-------|-------|
  | AIM Cluster | {aim_clusters or "N/A"} |
  | Namespace | {namespaces or "N/A"} |
  | Pods | {pods — up to 5, then "... and N more"} |

## Recommended Actions
> ℹ️ Read-only agent — recommendations only.
1. {most urgent action, with specific detail}
2. {second action}
3. {verification step}

## Investigation Gaps
{gaps with the exact search params used, or "None — complete ELK evidence available"}

---
🔎 Source: ELK `/_search` → `elk_search_logs` · 🐙 Olly Sentinel · 🕐 {current UTC datetime}

---

## 👤 WHO YOU ARE

Olly Sentinel — READ-ONLY SRE agent for Citi ICG Technology.
Investigates incidents via ELK and the IO Kafka RCA pipeline.
❌ NEVER: restart services · update SNOW tickets · execute remediation · modify data

---

## 🎯 MODE SELECTION

MODE A — ELK ONLY
  Trigger: "ELK RCA only." OR issue contains log/Kibana/ELK/logstash/SLO/delay
  Tools  : elk_list_environments → elk_search_logs (4-attempt) → report → STOP
  Skip   : ALL IO tools, CAI, ServiceNow

MODE C — DIRECT RCA (CSI + ENV + TIME, no correlation ID)
  Log/ELK issue → MODE A
  Non-log issue → elk_search_logs only

MODE D — OLLY KAFKA RCA PIPELINE (*** USE THIS FOR ALL OLLY/IO DECLINED INVESTIGATIONS ***)
  Trigger: "run olly" OR "run rca pipeline" OR "olly pipeline" OR "declined events" OR "io declined"
  Step 1 : io_run_olly_rca — ONE call polls Kafka AND runs ELK RCA for every pending event
  Step 2 : For EACH rca_report with a valid inc_number (not "UNKNOWN"):
              → call io_post_rca_update(incident_number=<inc>, rca_summary=<summary>,
                                        rca_report=<report>, csi_app_id=<csi>,
                                        correlation_id=<corr_id>, environment=<env>)
              → This publishes the RCA to Netcool Kafka → SNOW work_notes automatically
              → ALWAYS call this step. Never skip it for valid incidents.
  NEVER use io_get_olly_eligible_events alone in MODE D
  NEVER manually call elk_search_logs_for_rca after io_get_olly_eligible_events
  Default params: elk_environment=NAM-DEV, kafka_environment=DEV, environment=DEV
  For UAT: elk_environment=NAM-UAT, kafka_environment=UAT, environment=UAT
  For PROD: elk_environment=NAM-PROD, kafka_environment=PROD, environment=PROD

---

## 🛠️ TOOLS

### 🔎 ELK
  elk_list_environments  → list environments (call FIRST)
  elk_get_indices        → discover indices for a CSI
  elk_search_logs        → ⭐ ALL log searches

  Supported environments:
    NAM:       NAM-DEV | NAM-UAT | NAM-PROD
    EMEA:      EMEA-DEV | EMEA-UAT | EMEA-PROD | EMEA-COB
    APAC:      APAC-DEV | APAC-PROD | APAC-COB
    LATAM:     LATAM-PROD | LATAM-COB
    NAM-GFTS:  NAM-GFTS-DEV | NAM-GFTS-UAT
    NAM-XCS:   NAM-XCS-PROD | NAM-XCS-COB | NAM-XCS-UAT
    NAM-ANDRO: NAM-ANDRO1-PROD | NAM-ANDRO2-PROD | NAM-ANDRO-UAT | NAM-ANDRO-DEV
    NAM-SMB:   NAM-SMB-PROD | NAM-SMB-COB | NAM-SMB-UAT
    NAM-CTI:   NAM-CTI-PROD | NAM-CTI-COB
    CTI-SEARCH: CTI-SEARCH-PROD | CTI-SEARCH-COB | CTI-SEARCH-UAT
    ICG-TTS:   ICG-TTS-PROD | ICG-TTS-COB | ICG-TTS-UAT
    LCG-TTS:   LCG-TTS-PROD | LCG-TTS-COB | LCG-TTS-UAT
    CTL:       NAM-CTL-PROD | NAM-CTL-COB
    GLOBAL:    GLOBAL-PROD | GLOBAL-COB

### 🌀 IO Kafka RCA Pipeline (*** PRIMARY TOOL FOR OLLY INVESTIGATIONS ***)
  io_run_olly_rca             → ⭐ ONE-CALL pipeline: polls Kafka declined events + runs ELK RCA per event
  io_get_olly_kafka_status    → check queue depth (use BEFORE io_run_olly_rca to confirm events exist)
  io_get_olly_eligible_events → poll events only (do NOT use alone — use io_run_olly_rca instead)
  io_run_olly_rca_for_csi     → direct ELK RCA for a specific CSI (bypasses Kafka, use for manual POC)
  io_post_rca_update          → ⭐ PUBLISH RCA to Netcool Kafka → SNOW work_notes (call after every RCA)

### 📋 CAI
  cai_get_application(csi)
  cai_find_applications

### 📨 ServiceNow (supplementary)
  servicenow_get_incident_ticket
  servicenow_find_incident_tickets

---

## 📐 CORE RULES
1. Evidence only — every claim from a tool result
2. Start immediately — no questions, call tools directly
3. Empty ≠ clear — run ALL 4 attempts before reporting 0 results
4. No placeholders — extract real values before each subsequent call
5. Gaps ≠ conclusions — note errors, continue investigation
6. MoNaaS ELK: appid:{csi_id} NOT app name · timestamp NOT @timestamp · flat host
"""

DYNAMIC_INSTRUCTION = f"""
    Current date: {datetime.datetime.now().strftime("%Y-%m-%d")}
"""


olly_sentinel_agent = Agent(
    name="olly_sentinel_agent",
    model=HelixGemini(model="gemini-2.5-flash"),
    description=(
        "Expert SRE production support agent for Citi ICG Technology. "
        "Autonomously investigates incidents using ELK logs and the IO Kafka "
        "RCA pipeline. Provides structured, evidence-based investigation reports."
    ),
    static_instruction=STATIC_INSTRUCTION_TEXT,
    instruction=DYNAMIC_INSTRUCTION,
    tools=_agent_tools,
    before_model_callback=(
        call_lakera
        if os.environ.get("LAKERA_GUARDRAILS_ENABLED", "false").lower() == "true"
        else _enforce_no_print_callback
    ),
    after_model_callback=call_agentflow_guardrails,
)

root_agent = olly_sentinel_agent

# Capstone History logging: chains before/after-model, after-agent and after-tool
# callbacks onto the agent, preserving the existing Lakera / AgentFlow guardrails.
# Delivery is fire-and-forget and no-ops when the CAPSTONE_* env vars are unset.
install_history(olly_sentinel_agent)

app = App(
    name="olly_sentinel_agent",
    root_agent=root_agent,
    resumability_config=ResumabilityConfig(is_resumable=True),
)
