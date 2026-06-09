import json

import pytest

from harbor.models.agent.context import AgentContext

from zag_bench.agent import (
    PRACTICAL_CONSTRAINTS_SUFFIX,
    ZagAgent,
    decorate_instruction,
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


def test_decorate_instruction_preserves_task_text():
    task = "Recover the password from the corrupted archive."
    decorated = decorate_instruction(task)
    assert task in decorated


def test_decorate_instruction_appends_practical_constraints():
    decorated = decorate_instruction("do the thing")
    assert PRACTICAL_CONSTRAINTS_SUFFIX in decorated
    # The suffix is appended after the task text, not prepended.
    assert decorated.index("do the thing") < decorated.index(
        PRACTICAL_CONSTRAINTS_SUFFIX
    )


def test_practical_constraints_suffix_covers_batching_and_time():
    # The load-bearing directives, each tied to an evidenced k=1 failure
    # bucket: parallel batching + && chaining (weak tool batching in failing
    # trials), no redundant re-reads, the no-progress-loop circuit breaker
    # (40% of timeout cost was re-running the same failing command), the
    # self-verification gate (wrong-but-confident shipping), and acting once
    # enough is known (time is scarce).
    assert "parallel" in PRACTICAL_CONSTRAINTS_SUFFIX
    assert "&&" in PRACTICAL_CONSTRAINTS_SUFFIX
    assert "Never re-read" in PRACTICAL_CONSTRAINTS_SUFFIX
    assert "same" in PRACTICAL_CONSTRAINTS_SUFFIX  # no-progress-loop breaker
    assert "before you" in PRACTICAL_CONSTRAINTS_SUFFIX.lower()  # self-verify
    assert "Time is the scarcest resource" in PRACTICAL_CONSTRAINTS_SUFFIX


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


def test_run_uploads_decorated_instruction(tmp_path, monkeypatch):
    """Pins the wiring: run() must upload the DECORATED instruction, not the
    raw task text. Guards against a silent revert of the decorate_instruction
    call at the upload site."""
    import asyncio
    from types import SimpleNamespace

    agent = _make_agent(tmp_path)
    captured = {}

    async def fake_upload(host_path, container_path):
        with open(host_path, encoding="utf-8") as f:
            captured["uploaded"] = f.read()

    async def fake_exec(*args, **kwargs):
        captured["executed"] = True

    env = SimpleNamespace(upload_file=fake_upload)
    monkeypatch.setattr(agent, "exec_as_agent", fake_exec)
    asyncio.run(agent.run("solve the task", env, AgentContext()))

    assert captured["uploaded"].startswith("solve the task")
    assert PRACTICAL_CONSTRAINTS_SUFFIX in captured["uploaded"]
    assert captured["executed"]


def test_agent_reports_version_matching_atif(tmp_path):
    # The Hub "Agent Version" column reads BaseAgent.version(); without an
    # override it falls back to "unknown". It must match the version the ATIF
    # trajectory records (Trajectory.zig agent.version / build.zig.zon).
    agent = _make_agent(tmp_path)
    assert agent.version() == "0.1.0"
    assert agent.to_agent_info().version == "0.1.0"
