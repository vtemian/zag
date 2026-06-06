import json

import pytest

from harbor.models.agent.context import AgentContext

from zag_bench.agent import (
    ZagAgent,
    render_auth_json,
    resolve_api_key,
    split_model_name,
)


def test_split_model_name_passthrough():
    assert split_model_name("moonshot/kimi-k2.6") == ("moonshot", "kimi-k2.6")


def test_split_model_name_keeps_slashes_in_model():
    assert split_model_name("openai/org/model") == ("openai", "org/model")


def test_split_model_name_rejects_bare_model():
    with pytest.raises(ValueError):
        split_model_name("kimi-k2.6")


def test_split_model_name_rejects_unknown_provider():
    with pytest.raises(ValueError):
        split_model_name("bedrock/some-model")


def test_render_auth_json_shape():
    auth = json.loads(render_auth_json("moonshot", "sk-test-123"))
    assert auth == {"moonshot": {"type": "api_key", "key": "sk-test-123"}}


def test_resolve_api_key_reads_env(monkeypatch):
    monkeypatch.setenv("MOONSHOT_API_KEY", "sk-from-env")
    assert resolve_api_key("moonshot") == "sk-from-env"


def test_resolve_api_key_missing_raises(monkeypatch):
    monkeypatch.delenv("MOONSHOT_API_KEY", raising=False)
    with pytest.raises(RuntimeError, match="MOONSHOT_API_KEY"):
        resolve_api_key("moonshot")


def _make_agent(tmp_path):
    """Build a ZagAgent the way harbor's factory does: logs_dir + model_name kwargs."""
    return ZagAgent(logs_dir=tmp_path, model_name="moonshot/kimi-k2.6")


def test_populate_context_with_final_metrics(tmp_path):
    (tmp_path / "trajectory.json").write_text(
        json.dumps(
            {
                "final_metrics": {
                    "total_prompt_tokens": 1200,
                    "total_completion_tokens": 340,
                    "total_cached_tokens": 800,
                    "total_cost_usd": 0.0042,
                }
            }
        )
    )
    agent = _make_agent(tmp_path)
    context = AgentContext()
    agent.populate_context_post_run(context)
    assert context.n_input_tokens == 1200
    assert context.n_output_tokens == 340
    assert context.n_cache_tokens == 800
    assert context.cost_usd == 0.0042


def test_populate_context_without_final_metrics(tmp_path):
    # zag omits final_metrics entirely when per-step metrics are empty.
    (tmp_path / "trajectory.json").write_text(json.dumps({"steps": []}))
    agent = _make_agent(tmp_path)
    context = AgentContext()
    agent.populate_context_post_run(context)
    assert context.n_input_tokens is None
    assert context.n_output_tokens is None
    assert context.n_cache_tokens is None
    assert context.cost_usd is None


def test_populate_context_no_trajectory_file(tmp_path):
    agent = _make_agent(tmp_path)
    context = AgentContext()
    agent.populate_context_post_run(context)
    assert context.n_input_tokens is None
    assert context.cost_usd is None


def test_populate_context_malformed_trajectory(tmp_path):
    (tmp_path / "trajectory.json").write_text("{ this is not json")
    agent = _make_agent(tmp_path)
    context = AgentContext()
    agent.populate_context_post_run(context)
    assert context.n_input_tokens is None
    assert context.cost_usd is None


def test_populate_context_null_final_metrics(tmp_path):
    (tmp_path / "trajectory.json").write_text(json.dumps({"final_metrics": None}))
    agent = _make_agent(tmp_path)
    context = AgentContext()
    agent.populate_context_post_run(context)
    assert context.n_input_tokens is None
    assert context.cost_usd is None


def test_agent_name_is_zag():
    assert ZagAgent.name() == "zag"


def test_run_command_has_detached_snapshot_loop(tmp_path):
    # Harbor's timeout kills the host-side exec client, so no signal reaches
    # this shell and the trap alone cannot save the log. A setsid-detached
    # loop must snapshot the internal log through the /logs/agent bind-mount
    # on an interval, surviving the host-side kill.
    cmd = _make_agent(tmp_path)._build_run_command()
    assert "setsid bash -c" in cmd
    # Fully detached: no stdin, no stdout/stderr, backgrounded.
    assert "</dev/null >/dev/null 2>&1 &" in cmd
    # Snapshots overwrite (not append) on a 10s interval through the bind-mount.
    assert 'cat "$HOME"/.zag/logs/*.log > /logs/agent/zag-internal.log' in cmd
    assert "sleep 10" in cmd


def test_run_command_trap_overwrites_not_appends(tmp_path):
    # The detached loop already snapshots the full log each pass, so the
    # trap's final flush must overwrite (>); appending (>>) would duplicate
    # everything the loop already wrote.
    cmd = _make_agent(tmp_path)._build_run_command()
    assert (
        "trap 'cat \"$HOME\"/.zag/logs/*.log > /logs/agent/zag-internal.log 2>/dev/null' EXIT TERM INT"
        in cmd
    )
    assert ">> /logs/agent/zag-internal.log" not in cmd


def test_run_command_preserves_zag_invocation(tmp_path):
    # The detached loop and trap must wrap, not replace, the headless run that
    # pipes through tee so pipefail carries zag's exit code.
    cmd = _make_agent(tmp_path)._build_run_command()
    assert "/usr/local/bin/zag --headless" in cmd
    assert "--instruction-file=/tmp/zag-instruction.txt" in cmd
    assert "--trajectory-out=/logs/agent/trajectory.json" in cmd
    assert "tee /logs/agent/zag.txt" in cmd
