"""Load and enforce the versioned JSON Schemas. The contracts bake into the
image at /contracts; a payload that fails validation is dropped and counted,
never forwarded. The agent refuses to publish a payload that fails its
own contract."""

import json
import os
from functools import lru_cache

from jsonschema import Draft202012Validator

from . import config

ELIGIBLE_EVENT = "eligible-event.v1.schema.json"
RCA_ENRICHMENT = "rca-enrichment.v1.schema.json"
AGENT_CARD = "agent-card.olly-sentinel.v1.json"
PIPELINE_DECISION = "pipeline-decision.v1.schema.json"
ACTION_PROPOSAL = "action-proposal.v1.schema.json"
ORBIT_AGENT_CARD = "agent-card.orbit.v1.json"


def _path(name: str) -> str:
    return os.path.join(config.CONTRACTS_DIR, name)


@lru_cache(maxsize=None)
def load(name: str) -> dict:
    with open(_path(name), encoding="utf-8") as f:
        return json.load(f)


@lru_cache(maxsize=None)
def _validator(name: str) -> Draft202012Validator:
    return Draft202012Validator(load(name))


def validate(name: str, payload: dict) -> None:
    """Raise jsonschema.ValidationError when the payload drifts from the
    contract."""
    _validator(name).validate(payload)
