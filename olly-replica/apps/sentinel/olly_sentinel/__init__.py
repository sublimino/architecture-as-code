# Importing the package binds the module-level `root_agent` (agent.py), which
# is the symbol Google ADK's loader discovers when `adk web` / `adk eval` /
# AgentEvaluator are pointed at the `olly_sentinel` package, exactly as
# demo/adk-ops-assistant/ops_assistant/__init__.py exposes its agent. The
# Kafka (main.py) and A2A (a2a_server.py) entrypoints keep building their own
# runtime via build_agent()/SentinelRuntime(); this line only adds the ADK
# dev/eval front door onto the same object.
from . import agent  # noqa: F401
