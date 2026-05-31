#
# Copyright (c) 2024–2026, Daily
#
# SPDX-License-Identifier: BSD 2-Clause License
#

"""Cacty Voice — phone-driven Mac automation agent.

A caller says what they want done on their Mac ("add a calendar event
tomorrow at 3pm"). The bot has a short clarifying conversation, then hands a
single, complete instruction to Cacty — the macOS computer-use app — which
runs the task in the background and returns its real result. The bot relays
that result verbatim. It never claims success Cacty didn't report.

Pipeline (all NVIDIA on the voice path except TTS):
    Nemotron Speech Streaming STT → Nemotron-3-Super-120B LLM → Gradium TTS

The actual Mac automation is done by Cacty (Google Gemini under the hood),
reached over a loopback HTTP bridge — see ``cacty_client.py`` and
``cacty/Sources/App/Bridge/LocalTaskServer.swift``.

Run the bot using::

    uv run bot.py
"""

import os
from datetime import date

import aiohttp
from dotenv import load_dotenv
from loguru import logger
from pipecat.adapters.schemas.tools_schema import ToolsSchema
from pipecat.audio.vad.silero import SileroVADAnalyzer
from pipecat.frames.frames import EndTaskFrame, FunctionCallResultProperties, LLMRunFrame
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.worker import PipelineParams, PipelineWorker
from pipecat.processors.aggregators.llm_context import LLMContext
from pipecat.processors.aggregators.llm_response_universal import (
    LLMContextAggregatorPair,
    LLMUserAggregatorParams,
)
from pipecat.processors.frame_processor import FrameDirection
from pipecat.runner.types import (
    RunnerArguments,
    SmallWebRTCRunnerArguments,
    WebSocketRunnerArguments,
)
from pipecat.runner.utils import parse_telephony_websocket
from pipecat.serializers.twilio import TwilioFrameSerializer
from pipecat.services.gradium.tts import GradiumTTSService
from pipecat.services.llm_service import FunctionCallParams
from pipecat.transports.base_transport import BaseTransport, TransportParams
from pipecat.transports.smallwebrtc.connection import SmallWebRTCConnection
from pipecat.transports.smallwebrtc.transport import SmallWebRTCTransport
from pipecat.transports.websocket.fastapi import FastAPIWebsocketParams, FastAPIWebsocketTransport
from pipecat.turns.user_turn_strategies import FilterIncompleteUserTurnStrategies
from pipecat.workers.runner import WorkerRunner

from cacty_client import run_cacty_task
from nemotron_llm import VLLMOpenAILLMService
from nvidia_stt import NVidiaWebSocketSTTService

load_dotenv(override=True)


async def get_call_info(call_sid: str) -> dict:
    """Fetch call information from Twilio REST API using aiohttp.

    Args:
        call_sid: The Twilio call SID

    Returns:
        Dictionary containing call information including from_number, to_number.
    """
    account_sid = os.environ["TWILIO_ACCOUNT_SID"]
    auth_token = os.environ["TWILIO_AUTH_TOKEN"]

    if not account_sid or not auth_token:
        logger.warning("Missing Twilio credentials, cannot fetch call info")
        return {}

    url = f"https://api.twilio.com/2010-04-01/Accounts/{account_sid}/Calls/{call_sid}.json"

    try:
        auth = aiohttp.BasicAuth(account_sid, auth_token)
        async with aiohttp.ClientSession() as session:
            async with session.get(url, auth=auth) as response:
                if response.status != 200:
                    error_text = await response.text()
                    logger.error(f"Twilio API error ({response.status}): {error_text}")
                    return {}
                data = await response.json()
                return {
                    "from_number": data.get("from"),
                    "to_number": data.get("to"),
                }
    except Exception as e:
        logger.error(f"Error fetching call info from Twilio: {e}")
        return {}


async def run_bot(
    transport: BaseTransport,
    from_number: str | None = None,
    audio_in_sample_rate: int = 16000,
    audio_out_sample_rate: int = 24000,
):
    """Main bot logic.

    Args:
        transport: The transport to use.
        from_number: Caller's phone number (Twilio path only), for logging.
        audio_in_sample_rate: Input audio sample rate in Hz. Defaults to 16000.
        audio_out_sample_rate: Output audio sample rate in Hz. Defaults to 24000.
    """
    logger.info("Starting bot")

    cacty_url = os.getenv("CACTY_URL", "http://127.0.0.1:8765")

    # --- The single tool that does the work --------------------------------

    async def run_computer_task(params: FunctionCallParams, task: str) -> None:
        """Hand a complete, self-contained instruction to Cacty, which runs it
        on the user's Mac and returns the real result. Call this ONCE per task,
        only after you've gathered every detail you need and confirmed it with
        the caller.

        The result you get back is the ground truth — report it to the caller
        exactly. Never describe an outcome the result didn't state.

        Args:
            task: The full instruction in plain English, with every detail
                resolved into absolute terms (e.g. "Create an event in the
                Work calendar on Saturday, May 31st 2026 at 3pm titled
                'Dentist'"). Do not leave relative dates, pronouns, or
                "the calendar we discussed" — spell it all out.
        """
        logger.info(f"Dispatching to Cacty: {task!r}")
        result = await run_cacty_task(task, base_url=cacty_url)
        logger.info(f"Cacty result: {result}")
        # Pass Cacty's literal outcome straight to the LLM. The system prompt
        # forbids embellishing it.
        await params.result_callback(result)

    async def end_call(params: FunctionCallParams) -> None:
        """End the call. Only call this AFTER you have said goodbye to the
        caller in the same turn. The pipeline will flush any queued speech and
        then hang up."""
        logger.info("end_call invoked — pushing EndTaskFrame upstream")
        await params.llm.push_frame(EndTaskFrame(), FrameDirection.UPSTREAM)
        await params.result_callback(
            {"ok": True}, properties=FunctionCallResultProperties(run_llm=False)
        )

    tool_functions = [run_computer_task, end_call]
    tools = ToolsSchema(standard_tools=tool_functions)

    # --- System instruction -------------------------------------------------

    system_instruction = (
        "You are Cacty, a voice assistant that gets things done on the "
        "caller's Mac. The caller phones in, tells you what they want, and you "
        "carry it out by handing the task to a background agent that actually "
        "clicks through their apps.\n\n"
        "How you work:\n"
        "- Listen for what they want to do (create a calendar event, draft an "
        "email, find something, etc.).\n"
        "- Ask brief clarifying questions ONLY for details you genuinely need "
        "to do the task — and only the ones the task can't proceed without. "
        "For a calendar event that's usually: which calendar, the date and "
        "time, and a title. Ask ONE thing at a time.\n"
        "- Once you have what you need, confirm the whole task back in one "
        "short sentence and wait for a yes.\n"
        "- When they confirm, say a brief line like \"Okay, doing that now — "
        "give me a moment\" AND call run_computer_task in the SAME turn. The "
        "task takes a little while, so that line covers the wait.\n"
        "- Pass run_computer_task a COMPLETE instruction with every detail "
        "spelled out in absolute terms (real dates, not \"tomorrow\"; real "
        "calendar names, not \"that one\").\n\n"
        "Reporting results — THIS IS CRITICAL:\n"
        "- run_computer_task returns the ground truth. If it returns ok=true, "
        "tell the caller it's done and relay the text it gave you. If it "
        "returns ok=false, tell them it didn't work and plainly say the error. "
        "- NEVER claim something happened that the tool didn't report. NEVER "
        "invent confirmation numbers, details, or success. If you're unsure "
        "whether it worked, say exactly what the tool told you and nothing "
        "more.\n\n"
        "Talk like a real person on the phone, not a chatbot:\n"
        "- Keep it to 1–2 short sentences per turn.\n"
        '- Skip filler openers like "Absolutely!", "Perfect!", "I\'d be happy '
        'to" — go straight to the point.\n'
        "- Use contractions. Fragments are fine. No bullet points, no emojis — "
        "everything you say is spoken aloud.\n\n"
        "When the task is done and the caller has nothing else, or when they "
        'say goodbye: say a short closing line (e.g. "All set, talk soon!") AND '
        "call end_call in the same turn. Never call end_call without saying "
        "goodbye first.\n\n"
        f"Today is {date.today().strftime('%A, %B %d, %Y')}. Use this to turn "
        'relative dates like "tomorrow" or "this Friday" into absolute dates '
        "before sending the task to run_computer_task."
    )

    if from_number:
        logger.info(f"Call from: {from_number}")

    # --- Services -----------------------------------------------------------

    # STT — Nemotron Speech Streaming over WebSocket (16-bit PCM, 16 kHz mono).
    stt = NVidiaWebSocketSTTService(
        url=os.environ["NVIDIA_ASR_URL"],
        strip_interim_prefix=True,
    )

    # LLM — Nemotron-3-Super-120B via vLLM (OpenAI-compatible chat completions).
    # Thinking OFF for voice latency (see bot-nemotron.py for the full caveat).
    enable_thinking = os.getenv("NEMOTRON_ENABLE_THINKING", "false").lower() == "true"
    llm = VLLMOpenAILLMService(
        api_key=os.getenv("NEMOTRON_LLM_API_KEY", "EMPTY"),
        base_url=os.environ["NEMOTRON_LLM_URL"],
        settings=VLLMOpenAILLMService.Settings(
            model=os.getenv("NEMOTRON_LLM_MODEL", "nvidia/nemotron-3-super"),
            system_instruction=system_instruction,
            extra={"extra_body": {"chat_template_kwargs": {"enable_thinking": enable_thinking}}},
        ),
    )

    # TTS — Gradium (no NVIDIA TTS in this stack).
    tts = GradiumTTSService(
        api_key=os.environ["GRADIUM_API_KEY"],
        settings=GradiumTTSService.Settings(
            voice=os.getenv("GRADIUM_VOICE_ID", "Eu9iL_CYe8N-Gkx_"),
        ),
    )

    # ToolsSchema describes the tools to the LLM; register_direct_function
    # wires the actual handlers. Both are required.
    for fn in tool_functions:
        llm.register_direct_function(fn)

    context = LLMContext(tools=tools)
    user_aggregator, assistant_aggregator = LLMContextAggregatorPair(
        context,
        user_params=LLMUserAggregatorParams(
            vad_analyzer=SileroVADAnalyzer(),
            user_turn_strategies=FilterIncompleteUserTurnStrategies(),
        ),
    )

    pipeline = Pipeline(
        [
            transport.input(),
            stt,
            user_aggregator,
            llm,
            tts,
            transport.output(),
            assistant_aggregator,
        ]
    )

    worker = PipelineWorker(
        pipeline,
        params=PipelineParams(
            enable_metrics=True,
            enable_usage_metrics=True,
            audio_in_sample_rate=audio_in_sample_rate,
            audio_out_sample_rate=audio_out_sample_rate,
        ),
    )

    @transport.event_handler("on_client_connected")
    async def on_client_connected(transport, client):
        logger.info("Client connected")
        context.add_message(
            {
                "role": "user",
                "content": (
                    "The caller just connected. Greet them briefly: "
                    "\"Hey, it's Cacty. What can I do for you?\""
                ),
            }
        )
        await worker.queue_frames([LLMRunFrame()])

    @transport.event_handler("on_client_disconnected")
    async def on_client_disconnected(transport, client):
        logger.info("Client disconnected")
        await worker.cancel()

    runner = WorkerRunner(handle_sigint=False)
    await runner.add_workers(worker)
    await runner.run()


async def bot(runner_args: RunnerArguments):
    """Main bot entry point."""

    from_number: str | None = None
    transport_overrides: dict = {}

    # Krisp is available when deployed to Pipecat Cloud.
    if os.environ.get("ENV") != "local":
        from pipecat.audio.filters.krisp_viva_filter import KrispVivaFilter

        krisp_filter = KrispVivaFilter()
    else:
        krisp_filter = None

    match runner_args:
        case SmallWebRTCRunnerArguments():
            webrtc_connection: SmallWebRTCConnection = runner_args.webrtc_connection
            transport = SmallWebRTCTransport(
                webrtc_connection=webrtc_connection,
                params=TransportParams(
                    audio_in_enabled=True,
                    audio_in_filter=krisp_filter,
                    audio_out_enabled=True,
                ),
            )
        case WebSocketRunnerArguments():
            # Twilio media streams are 8 kHz μ-law in both directions.
            transport_overrides["audio_in_sample_rate"] = 8000
            transport_overrides["audio_out_sample_rate"] = 8000

            _, call_data = await parse_telephony_websocket(runner_args.websocket)
            call_info = await get_call_info(call_data["call_id"])
            if call_info:
                from_number = call_info.get("from_number")
                logger.info(f"Call from: {from_number} to: {call_info.get('to_number')}")

            serializer = TwilioFrameSerializer(
                stream_sid=call_data["stream_id"],
                call_sid=call_data["call_id"],
                account_sid=os.environ["TWILIO_ACCOUNT_SID"],
                auth_token=os.environ["TWILIO_AUTH_TOKEN"],
            )
            transport = FastAPIWebsocketTransport(
                websocket=runner_args.websocket,
                params=FastAPIWebsocketParams(
                    audio_in_enabled=True,
                    audio_in_filter=krisp_filter,
                    audio_out_enabled=True,
                    add_wav_header=False,
                    serializer=serializer,
                ),
            )
        case _:
            logger.error(f"Unsupported runner arguments type: {type(runner_args)}")
            return

    await run_bot(transport, from_number=from_number, **transport_overrides)


if __name__ == "__main__":
    from pipecat.runner.run import main

    main()
