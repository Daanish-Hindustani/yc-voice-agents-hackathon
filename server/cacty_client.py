#
# Copyright (c) 2024–2026, Daily
#
# SPDX-License-Identifier: BSD 2-Clause License
#

"""Thin async client for the Cacty loopback bridge.

Cacty (the macOS computer-use app) exposes a single loopback HTTP endpoint
(see ``cacty/Sources/App/Bridge/LocalTaskServer.swift``):

    POST /task  {"prompt": "<task>"}  → {"ok": bool, "text"|"error": str}

The call is synchronous on Cacty's side: it blocks until the agent's worker
loop terminates, so a single ``run_cacty_task`` await maps to one completed
task. Tasks take tens of seconds, hence the generous default timeout.

This module owns exactly one responsibility: turn a natural-language task
string into Cacty's literal result text (or a clear error), with no
interpretation. The bot relays that text verbatim — the no-hallucination
contract lives here and in the system prompt, not in invented success.
"""

import aiohttp

# Cacty's bridge runs on the same Mac as the bot (it automates THIS machine),
# so the URL is always loopback. Overridable via CACTY_URL for a non-default
# port (must match CACTY_BRIDGE_PORT passed to Cacty).
DEFAULT_CACTY_URL = "http://127.0.0.1:8765"

# Cacty's own per-task ceiling is 300s (LocalTaskServer maxWait). Give the
# HTTP client a little more headroom than that so the bridge's own timeout
# response wins the race and we surface its message, not a client abort.
TASK_TIMEOUT_SECONDS = 330


async def run_cacty_task(prompt: str, base_url: str = DEFAULT_CACTY_URL) -> dict:
    """Send a task to Cacty and wait for the real outcome.

    Args:
        prompt: The complete, self-contained instruction for Cacty to carry
            out on the Mac (e.g. "Create a calendar event in the Work
            calendar tomorrow at 3pm titled Dentist").
        base_url: Bridge base URL. Defaults to loopback:8765.

    Returns:
        A dict with a normalized shape the caller can speak directly:
            {"ok": True,  "text": "<Cacty's final text>"}        on success
            {"ok": False, "error": "<reason>"}                   on failure

        Never raises — transport/timeout problems are caught and returned as
        ``{"ok": False, "error": ...}`` so the voice bot always has something
        truthful to say rather than crashing the call.
    """
    timeout = aiohttp.ClientTimeout(total=TASK_TIMEOUT_SECONDS)
    url = f"{base_url.rstrip('/')}/task"

    try:
        async with aiohttp.ClientSession(timeout=timeout) as session:
            async with session.post(url, json={"prompt": prompt}) as response:
                if response.status != 200:
                    body = await response.text()
                    return {
                        "ok": False,
                        "error": f"Cacty returned HTTP {response.status}: {body[:200]}",
                    }
                data = await response.json()
                # Trust Cacty's own ok/text/error shape; normalize defensively.
                if data.get("ok"):
                    return {"ok": True, "text": data.get("text", "")}
                return {"ok": False, "error": data.get("error", "unknown error")}

    except aiohttp.ClientConnectorError:
        return {
            "ok": False,
            "error": (
                "Can't reach Cacty. Make sure the Cacty app is running on this "
                "Mac with its bridge enabled."
            ),
        }
    except TimeoutError:
        return {
            "ok": False,
            "error": "The task took too long and timed out.",
        }
    except aiohttp.ClientError as e:
        return {"ok": False, "error": f"Connection error talking to Cacty: {e}"}


async def cacty_is_healthy(base_url: str = DEFAULT_CACTY_URL) -> bool:
    """Liveness probe against the bridge's GET /health. Best-effort; returns
    False on any error so the bot can warn the caller early instead of
    discovering Cacty is down only after they describe a whole task."""
    timeout = aiohttp.ClientTimeout(total=3)
    url = f"{base_url.rstrip('/')}/health"
    try:
        async with aiohttp.ClientSession(timeout=timeout) as session:
            async with session.get(url) as response:
                if response.status != 200:
                    return False
                data = await response.json()
                return bool(data.get("ok"))
    except (aiohttp.ClientError, TimeoutError):
        return False
