import logging

import pytest

from adapters import load_adapter_selections


def test_defaults_select_all_demo_backends(caplog):
    with caplog.at_level(logging.INFO):
        selections = load_adapter_selections({})

    assert all(selection.enabled for selection in selections.values())
    assert selections["LLM discovery"].backend == "fake-openai"
    assert "state=enabled" in caplog.text


def test_optional_connector_can_be_disabled_and_is_visible(caplog):
    with caplog.at_level(logging.INFO):
        selections = load_adapter_selections({"CRM_BACKEND": "disabled"})

    assert selections["CRM"].enabled is False
    assert "category=CRM backend=disabled state=disabled" in caplog.text


@pytest.mark.parametrize("environment, message", [
    ({"LLM_DISCOVERY_BACKEND": "disabled"}, "cannot be disabled"),
    ({"NOTIFICATION_BACKEND": "unknown"}, "unknown notification backend"),
])
def test_invalid_adapter_configuration_fails_startup(environment, message):
    with pytest.raises(ValueError, match=message):
        load_adapter_selections(environment)
