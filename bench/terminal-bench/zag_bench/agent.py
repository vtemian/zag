"""Harbor installed-agent adapter that runs zag headless in task containers.

zag reads API keys only from ~/.config/zag/auth.json (no env fallback), so
install() synthesizes that file from the host environment. The model is passed
through verbatim: harbor's -m "provider/model" becomes ZAG_BENCH_MODEL, which
the bench config.lua feeds to zag.set_default_model().
"""

import json
import os
import tempfile
from pathlib import Path

from harbor.agents.installed.base import BaseInstalledAgent, with_prompt_template
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext

_KEY_ENV_BY_PROVIDER = {
    "moonshot": "MOONSHOT_API_KEY",
    "anthropic": "ANTHROPIC_API_KEY",
    "openai": "OPENAI_API_KEY",
}

_CONTAINER_BIN = "/usr/local/bin/zag"
_CONTAINER_INSTRUCTION = "/tmp/zag-instruction.txt"
_CONTAINER_TRAJECTORY = "/logs/agent/trajectory.json"
_CONTAINER_LOG = "/logs/agent/zag.txt"

_BENCH_DIR = Path(__file__).resolve().parent.parent
_DEFAULT_BINARY = _BENCH_DIR / "bin" / "zag-linux-aarch64"
_BENCH_CONFIG = _BENCH_DIR / "zag-config.lua"


def split_model_name(model_name: str) -> tuple[str, str]:
    """Split harbor's "provider/model" into (provider, model)."""
    if not model_name or "/" not in model_name:
        raise ValueError(
            f"model name must be 'provider/model', got {model_name!r}"
        )
    provider, model = model_name.split("/", 1)
    if provider not in _KEY_ENV_BY_PROVIDER:
        raise ValueError(
            f"unsupported provider {provider!r}; known: {sorted(_KEY_ENV_BY_PROVIDER)}"
        )
    return provider, model


def resolve_api_key(provider: str) -> str:
    """Read the provider's API key from the host environment."""
    env_name = _KEY_ENV_BY_PROVIDER[provider]
    key = os.environ.get(env_name)
    if not key:
        raise RuntimeError(
            f"{env_name} is not set on the host; export it or use run.sh"
        )
    return key


def render_auth_json(provider: str, api_key: str) -> str:
    """Render the auth store zag expects at ~/.config/zag/auth.json."""
    return json.dumps({provider: {"type": "api_key", "key": api_key}})


class ZagAgent(BaseInstalledAgent):
    SUPPORTS_ATIF: bool = True

    def __init__(self, *args, **kwargs):
        self._binary = Path(kwargs.pop("binary", _DEFAULT_BINARY))
        super().__init__(*args, **kwargs)

    @staticmethod
    def name() -> str:
        return "zag"

    async def install(self, environment: BaseEnvironment) -> None:
        if not self._binary.is_file():
            raise FileNotFoundError(
                f"{self._binary} missing; run bench/terminal-bench/build-linux.sh"
            )
        provider, _ = split_model_name(self.model_name)
        api_key = resolve_api_key(provider)

        await environment.upload_file(self._binary, _CONTAINER_BIN)
        await environment.upload_file(_BENCH_CONFIG, "/tmp/zag-config.lua")

        # zag's std.http TLS needs a CA bundle; ubuntu:24.04 base lacks one.
        await self.exec_as_root(
            environment,
            command=(
                f"chmod 755 {_CONTAINER_BIN} && "
                "(test -f /etc/ssl/certs/ca-certificates.crt || "
                "(apt-get update && apt-get install -y --no-install-recommends ca-certificates))"
            ),
            env={"DEBIAN_FRONTEND": "noninteractive"},
        )

        # Config + auth store under the agent user's HOME. The key travels as
        # an env var and is expanded by the container shell, mirroring how
        # harbor's own kimi_cli adapter handles credentials.
        await self.exec_as_agent(
            environment,
            command=(
                'mkdir -p "$HOME/.config/zag" && '
                'cp /tmp/zag-config.lua "$HOME/.config/zag/config.lua" && '
                "umask 077 && "
                'printf "%s" "$ZAG_AUTH_JSON" > "$HOME/.config/zag/auth.json"'
            ),
            env={"ZAG_AUTH_JSON": render_auth_json(provider, api_key)},
        )

    @with_prompt_template
    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        with tempfile.NamedTemporaryFile(
            "w", suffix=".txt", delete=False, encoding="utf-8"
        ) as f:
            f.write(instruction)
            host_instruction = f.name
        try:
            await environment.upload_file(host_instruction, _CONTAINER_INSTRUCTION)
        finally:
            os.unlink(host_instruction)

        # zag is silent on stdout; its diagnostics go to $HOME/.zag/logs.
        # Copy that log into /logs/agent so harbor collects it, preserving
        # zag's exit code (pipefail carries it through the tee).
        await self.exec_as_agent(
            environment,
            command=(
                f"{_CONTAINER_BIN} --headless "
                f"--instruction-file={_CONTAINER_INSTRUCTION} "
                f"--trajectory-out={_CONTAINER_TRAJECTORY} "
                f"--no-session 2>&1 | stdbuf -oL tee {_CONTAINER_LOG}; "
                'rc=$?; cat "$HOME"/.zag/logs/*.log >> /logs/agent/zag-internal.log 2>/dev/null; '
                "exit $rc"
            ),
            env={"ZAG_BENCH_MODEL": self.model_name},
        )

    def populate_context_post_run(self, context: AgentContext) -> None:
        trajectory_path = self.logs_dir / "trajectory.json"
        if not trajectory_path.exists():
            return
        try:
            trajectory = json.loads(trajectory_path.read_text())
        except (OSError, json.JSONDecodeError):
            self.logger.exception("unreadable zag trajectory")
            return
        fm = trajectory.get("final_metrics") or {}
        context.n_input_tokens = fm.get("total_prompt_tokens")
        context.n_output_tokens = fm.get("total_completion_tokens")
        context.n_cache_tokens = fm.get("total_cached_tokens")
        context.cost_usd = fm.get("total_cost_usd")
