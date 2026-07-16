"""Self-Healing SRE Agent Pipeline - Monitored by SigNoz via OpenTelemetry.

Every manual span carries three custom attributes:

    agent.persona            str     Pipeline stage identifier
    token.cost.accumulated   float   Simulated cumulative token cost
    dread.level              int     Panic level (0 = success, 7-10 = critical)

Pipeline stages
---------------
    task_runner   -> execute_task()              Simulated agent execution
    error_detector -> detect_anomaly()            Anomaly flagging
    sre_analyst    -> sre_heal_loop()             MCP-driven diagnosis
    code_healer    -> pipeline.code_patch span    Patch generation
    load_injector  -> background_load_injector()  Synthetic task loop

Each execution emits three OpenTelemetry metrics counters:
    pipeline_tasks_total      Total executions count
    pipeline_heals_total      Successful healing interventions
    pipeline_money_saved_total  Cumulative demo ROI (USD)
"""

from __future__ import annotations

# -- Standard Library --------------------------------------------------------
import asyncio
import logging
import os
import random
import time
import uuid
from typing import Any

# -- Third-Party -------------------------------------------------------------
import httpx
from fastapi import FastAPI
from pydantic import BaseModel

# -- OpenTelemetry (initialised before application code) ---------------------
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import SERVICE_NAME, Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.trace import Status, StatusCode
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry import metrics

# ============================================================================
# 1.  OpenTelemetry Bootstrap
# ============================================================================

_resource = Resource.create(
    attributes={
        SERVICE_NAME: os.environ.get(
            "OTEL_SERVICE_NAME",
            "self-healing-sre-pipeline",
        )
    }
)
_provider = TracerProvider(resource=_resource)
_provider.add_span_processor(
    BatchSpanProcessor(
        OTLPSpanExporter(
            endpoint=os.environ.get(
                "OTEL_EXPORTER_OTLP_ENDPOINT",
                "http://localhost:4317",
            ),
            insecure=True,
        )
    )
)
trace.set_tracer_provider(_provider)

tracer: trace.Tracer = trace.get_tracer(__name__)


# ============================================================================
# 2.  OpenTelemetry Metrics Bootstrap
# ============================================================================

_metric_reader = PeriodicExportingMetricReader(
    OTLPMetricExporter(
        endpoint=os.environ.get(
            "OTEL_EXPORTER_OTLP_ENDPOINT",
            "http://localhost:4317",
        ),
        insecure=True,
    )
)
_meter_provider = MeterProvider(resource=_resource, metric_readers=[_metric_reader])
metrics.set_meter_provider(_meter_provider)

_meter: metrics.Meter = metrics.get_meter("pipeline.metrics")

# -- Persistent counters ------------------------------------------------------

pipeline_tasks_counter = _meter.create_counter(
    name="pipeline_tasks_total",
    description="Total number of pipeline task executions",
    unit="1",
)
pipeline_heals_counter = _meter.create_counter(
    name="pipeline_heals_total",
    description="Total number of successful automated healing interventions",
    unit="1",
)
pipeline_money_saved_counter = _meter.create_counter(
    name="pipeline_money_saved_total",
    description="Cumulative financial ROI saved via pipeline automation (USD)",
    unit="USD",
)
pipeline_errors_counter = _meter.create_counter(
    name="pipeline_task_errors_total",
    description="Total number of failed pipeline task executions",
    unit="1",
)


# ============================================================================
# 3.  Configuration
# ============================================================================

# Pipeline failure probability (0.0 - 1.0). Set PIPELINE_FAILURE_RATE env var to override.
_FAILURE_RATE = float(os.environ.get("PIPELINE_FAILURE_RATE", "0.30"))


# ============================================================================
# 4.  Logger
# ============================================================================

_logger = logging.getLogger("self-healing-sre-pipeline")
_logger.setLevel(logging.INFO)

_handler = logging.StreamHandler()
_handler.setFormatter(
    logging.Formatter(
        fmt="%(asctime)s  [%(levelname)s]  %(name)s  |  %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S%z",
    )
)
_logger.addHandler(_handler)


# ============================================================================
# 5.  Data Models  (Pydantic)
# ============================================================================

class PipelineTask(BaseModel):
    """A single unit of work submitted to the agent pipeline."""

    task_id: str
    prompt: str
    target_service: str
    max_budget: float


class TaskResult(BaseModel):
    """Outcome of executing a single pipeline task."""

    task_id: str
    success: bool
    output: str | None
    error: str | None
    latency_ms: float
    token_cost: float
    dread_level: int


class HealingAction(BaseModel):
    """Diagnosis + patch produced by the SRE healing loop."""

    trace_id: str
    failing_span_id: str
    diagnosis: str
    patch_code: str
    applied: bool


# ============================================================================
# 6.  In-Memory Stats Collector  (asyncio.Lock protected)
# ============================================================================

_stats: dict[str, int | float] = {
    "total_tasks": 0,
    "successful": 0,
    "failed": 0,
    "healed": 0,
    "total_token_cost": 0.0,
}
_stats_lock = asyncio.Lock()


async def _update_stats(**kwargs: int | float) -> None:
    """Atomically apply incremental updates to the in-memory counters."""
    async with _stats_lock:
        for key, delta in kwargs.items():
            if key in _stats:
                _stats[key] += delta


# ============================================================================
# 7.  Core Agent Pipeline  (async-only)
# ============================================================================

_FAILURE_MESSAGES: list[str] = [
    "LLM output exceeded context window",
    "API rate limit breached",
    "Null pointer in agentic loop",
    "Function call returned hallucinated tool result",
    "Embedding dimension mismatch in vector store lookup",
    "Maximum retry budget exhausted for upstream dependency",
]


# -- 7a.  execute_task -------------------------------------------------------

async def execute_task(task: PipelineTask) -> TaskResult:
    """Simulate an agentic task execution with a configurable failure rate.

    Wraps work inside a ``pipeline.execute_task`` span.
    Controlled by the ``PIPELINE_FAILURE_RATE`` env var (default 30%).
    """
    start = time.monotonic()

    with tracer.start_as_current_span("pipeline.execute_task") as span:
        span.set_attribute("agent.persona", "task_runner")
        span.set_attribute("agent.task_id", task.task_id)
        span.set_attribute("agent.target_service", task.target_service)

        # Simulate LLM inference latency
        await asyncio.sleep(random.uniform(0.3, 1.2))

        token_cost = round(random.uniform(0.5, 15.0), 4)
        span.set_attribute("token.cost.accumulated", token_cost)

        # Inject a random failure at the configured rate
        try:
            if random.random() < _FAILURE_RATE:
                raise RuntimeError(random.choice(_FAILURE_MESSAGES))

            span.set_status(Status(StatusCode.OK))
            span.set_attribute("dread.level", 0)

            elapsed = round((time.monotonic() - start) * 1000, 2)
            return TaskResult(
                task_id=task.task_id,
                success=True,
                output=f"Successfully processed: {task.prompt[:60]}",
                error=None,
                latency_ms=elapsed,
                token_cost=token_cost,
                dread_level=0,
            )

        except RuntimeError as exc:
            span.record_exception(exc)
            span.set_status(Status(StatusCode.ERROR))

            dread = random.randint(7, 10)
            span.set_attribute("dread.level", dread)

            elapsed = round((time.monotonic() - start) * 1000, 2)
            return TaskResult(
                task_id=task.task_id,
                success=False,
                output=None,
                error=str(exc),
                latency_ms=elapsed,
                token_cost=token_cost,
                dread_level=dread,
            )


# -- 7b.  detect_anomaly -----------------------------------------------------

async def detect_anomaly(result: TaskResult) -> bool:
    """Return ``True`` when a task result needs a healing intervention.

    Triggers on:
    *  task failure (``success is False``)
    *  high latency (``> 2000 ms``)
    *  excessive token cost (``> 10.0``)
    """
    with tracer.start_as_current_span("pipeline.detect_anomaly") as span:
        span.set_attribute("agent.persona", "error_detector")
        span.set_attribute("token.cost.accumulated", result.token_cost)
        span.set_attribute("dread.level", result.dread_level)

        is_anomaly = (
            not result.success
            or result.latency_ms > 2000
            or result.token_cost > 10.0
        )
        span.set_attribute("anomaly.detected", is_anomaly)
        return is_anomaly


# -- 7c.  MCP helpers --------------------------------------------------------

async def _mcp_call_tool(
    client: httpx.AsyncClient,
    tool: str,
    arguments: dict[str, Any],
) -> dict[str, Any]:
    """POST a tool call to the local SigNoz MCP server."""
    response = await client.post(
        "http://localhost:8000/mcp/call_tool",
        json={"tool": tool, "arguments": arguments},
        timeout=10.0,
    )
    response.raise_for_status()
    return response.json()  # type: ignore[no-any-return]


def _extract_mcp_text(payload: dict[str, Any], field: str) -> str | None:
    """Try to extract a field from an MCP response, inspecting ``content`` first."""
    content = payload.get("content", [])
    if isinstance(content, list) and content:
        first = content[0]
        if isinstance(first, dict):
            value = first.get("text") or first.get(field)
            if value and isinstance(value, str):
                return value
        elif isinstance(first, str):
            return first[:64]
    fallback = payload.get(field)
    return str(fallback) if fallback is not None else None


async def _generate_fallback_healing(
    task: PipelineTask,
    result: TaskResult,
) -> HealingAction:
    """Build a fallback ``HealingAction`` when the MCP server is unreachable."""
    return HealingAction(
        trace_id=uuid.uuid4().hex,
        failing_span_id=uuid.uuid4().hex[:16],
        diagnosis=(
            f"Offline fallback diagnosis for task {task.task_id!r}: {result.error}"
        ),
        patch_code=(
            "# Fallback null-guard patch\n"
            "def safe_get(data: dict, key: str, default: Any = None) -> Any:\n"
            '    """Safely retrieve a dict key, falling back to *default*."""\n'
            "    try:\n"
            "        return data.get(key, default)\n"
            "    except AttributeError:\n"
            "        return default\n\n"
            'result = safe_get(data, "result", default={})\n'
        ),
        applied=True,
    )


# -- 7d.  sre_heal_loop ------------------------------------------------------

async def sre_heal_loop(
    task: PipelineTask,
    result: TaskResult,
) -> HealingAction | None:
    """MCP-driven SRE healing loop (iterative, never recursive).

    Steps
    -----
    1.  Call ``signoz_search_traces`` - fetch the 5 most recent error traces.
    2.  Call ``signoz_get_trace_details`` - get span details for the latest
        failing trace.
    3.  **Diagnose** - produce a human-readable root cause.
    4.  **Patch** - generate a contextualised Python code patch.

    Gracefully degrades to a fallback ``HealingAction`` when the MCP server
    is unreachable.
    """
    with tracer.start_as_current_span("pipeline.sre_heal_loop") as heal_span:
        heal_span.set_attribute("agent.persona", "sre_analyst")
        heal_span.set_attribute(
            "token.cost.accumulated",
            round(random.uniform(1.0, 8.0), 4),
        )
        heal_span.set_attribute("dread.level", result.dread_level)

        # Default values in case of early bail-out
        trace_id: str = uuid.uuid4().hex
        failing_span_id: str = uuid.uuid4().hex[:16]
        diagnosis = "No diagnosis could be made (MCP request failed)."
        patch_code = "# No patch generated."
        healing_applied = False

        try:
            async with httpx.AsyncClient() as client:
                # Search failing traces
                search_resp = await _mcp_call_tool(
                    client,
                    "signoz_search_traces",
                    {
                        "serviceName": "self-healing-sre-pipeline",
                        "status": "error",
                        "limit": 5,
                    },
                )
                _logger.info("MCP signoz_search_traces response received.")

                extracted_trace = _extract_mcp_text(search_resp, "traceId")
                if extracted_trace:
                    trace_id = extracted_trace

                # Fetch trace details
                detail_resp = await _mcp_call_tool(
                    client,
                    "signoz_get_trace_details",
                    {"traceId": trace_id},
                )
                _logger.info("MCP signoz_get_trace_details response received.")

                extracted_span = _extract_mcp_text(detail_resp, "spanId")
                if extracted_span:
                    failing_span_id = extracted_span[:16]

                # Diagnose
                with tracer.start_as_current_span(
                    "pipeline.sre_diagnose"
                ) as diag_span:
                    diag_span.set_attribute("agent.persona", "sre_analyst")
                    diag_span.set_attribute(
                        "token.cost.accumulated",
                        round(random.uniform(0.5, 4.0), 4),
                    )
                    diag_span.set_attribute("dread.level", result.dread_level)

                    diagnosis = (
                        f"Detected failure in trace {trace_id!r} "
                        f"(span {failing_span_id!r}): {result.error}. "
                        f"Suspect missing null-guard on LLM response path."
                    )

                # Generate patch
                with tracer.start_as_current_span(
                    "pipeline.code_patch"
                ) as patch_span:
                    patch_span.set_attribute("agent.persona", "code_healer")
                    patch_span.set_attribute(
                        "token.cost.accumulated",
                        round(random.uniform(0.5, 3.0), 4),
                    )
                    patch_span.set_attribute("dread.level", result.dread_level)

                    # Contextualise the patch based on the error message
                    keyword_field_map: dict[str, str] = {
                        "context": "max_tokens",
                        "rate limit": "retry_after",
                        "pointer": "Optional",
                        "hallucinated": "tool_call_id",
                        "dimension": "embedding_dim",
                        "retry": "max_attempts",
                    }
                    chosen_field = "result"
                    if result.error:
                        for keyword, field in keyword_field_map.items():
                            if keyword in result.error.lower():
                                chosen_field = field
                                break

                    patch_code = (
                        f"# Auto-generated patch for: {result.error}\n"
                        "def safe_get(data: dict, key: str, default: Any = None) -> Any:\n"
                        '    """Safely retrieve a dictionary key with a fallback default."""\n'
                        "    try:\n"
                        "        return data.get(key, default)\n"
                        "    except AttributeError:\n"
                        "        return default\n\n"
                        f'result = safe_get(data, "{chosen_field}", default={{}})\n'
                    )

                    patch_span.set_attribute(
                        "healing.patch_length",
                        len(patch_code),
                    )

                healing_applied = True

            heal_span.set_status(Status(StatusCode.OK))

        except (httpx.RequestError, httpx.HTTPStatusError) as exc:
            _logger.warning(
                "MCP server unreachable (%s); using fallback healing.",
                exc,
            )
            heal_span.record_exception(exc)
            heal_span.set_status(Status(StatusCode.ERROR))
            return await _generate_fallback_healing(task, result)

        return HealingAction(
            trace_id=trace_id,
            failing_span_id=failing_span_id,
            diagnosis=diagnosis,
            patch_code=patch_code,
            applied=healing_applied,
        )


# -- 7e.  run_pipeline (orchestrator) ----------------------------------------

async def run_pipeline(task: PipelineTask) -> dict[str, Any]:
    """Orchestrate the full agent pipeline and update global counters.

    Returns a summary dict with keys:
        task_id, success, healing_applied, total_cost, total_latency_ms
    """
    start = time.monotonic()

    summary: dict[str, Any] = {
        "task_id": task.task_id,
        "success": True,
        "healing_applied": False,
        "total_cost": 0.0,
        "total_latency_ms": 0.0,
    }

    # Step 1 - Execute
    result = await execute_task(task)

    # ── OTel Metrics counters ────────────────────────────────────────────
    pipeline_tasks_counter.add(1)

    if result.success:
        pipeline_money_saved_counter.add(result.token_cost)
        await _update_stats(successful=1)
    else:
        summary["success"] = False
        pipeline_errors_counter.add(1)
        await _update_stats(failed=1)

    summary["total_cost"] = result.token_cost
    await _update_stats(total_token_cost=result.token_cost, total_tasks=1)

    # Step 2 - Detect anomaly
    if await detect_anomaly(result):
        _logger.info(
            "Anomaly detected for task %r; entering healing loop.",
            task.task_id,
        )
        healing = await sre_heal_loop(task, result)
        if healing is not None and healing.applied:
            summary["healing_applied"] = True
            pipeline_heals_counter.add(1)
            # Healing restores the business value of a failed execution
            pipeline_money_saved_counter.add(result.token_cost)
            await _update_stats(healed=1)

    summary["total_latency_ms"] = round((time.monotonic() - start) * 1000, 2)
    return summary


# ============================================================================
# 8.  Background Load Injector
# ============================================================================

_background_task: asyncio.Task[None] | None = None


async def _background_load_injector() -> None:
    """Submit synthetic pipeline tasks every 5 seconds.

    Guarantees a continuous stream of traces flowing into SigNoz,
    making dashboards and alerts immediately useful during development.
    """
    while True:
        task = PipelineTask(
            task_id=f"syn-{uuid.uuid4().hex[:8]}",
            prompt="Simulate user query",
            target_service="self-healing-sre-pipeline",
            max_budget=50.0,
        )

        with tracer.start_as_current_span("load_injector.task") as span:
            span.set_attribute("agent.persona", "load_injector")
            span.set_attribute("dread.level", 0)

            try:
                result = await run_pipeline(task)

                span.set_attribute("pipeline.success", result["success"])
                span.set_attribute(
                    "pipeline.total_latency_ms",
                    result["total_latency_ms"],
                )
                span.set_attribute(
                    "token.cost.accumulated",
                    result["total_cost"],
                )

                _logger.debug(
                    "Load injector | task=%s  success=%s  latency=%.1fms",
                    task.task_id,
                    result["success"],
                    result["total_latency_ms"],
                )

            except Exception as exc:  # noqa: BLE001
                _logger.exception(
                    "Load injector | task=%s failed unexpectedly",
                    task.task_id,
                )
                span.record_exception(exc)
                span.set_status(Status(StatusCode.ERROR))
                span.set_attribute("pipeline.success", False)

        await asyncio.sleep(5)


# ============================================================================
# 9.  FastAPI Application
# ============================================================================

app = FastAPI(
    title="Self-Healing SRE Pipeline",
    description=(
        "An AI-powered self-healing agent pipeline instrumented with "
        "OpenTelemetry and monitored by SigNoz."
    ),
    version="1.0.0",
)


# -- Lifecycle hooks ---------------------------------------------------------

@app.on_event("startup")
async def _on_startup() -> None:
    """Launch the background load injector when the application starts."""
    global _background_task  # noqa: PLW0603
    _background_task = asyncio.create_task(_background_load_injector())
    _logger.info("Background load injector started.")


@app.on_event("shutdown")
async def _on_shutdown() -> None:
    """Gracefully cancel the background load injector on shutdown."""
    global _background_task  # noqa: PLW0603
    if _background_task is not None:
        _background_task.cancel()
        try:
            await _background_task
        except asyncio.CancelledError:
            pass
        _background_task = None
        _logger.info("Background load injector stopped.")


# -- Endpoints ----------------------------------------------------------------

@app.get("/health")
async def health() -> dict[str, str]:
    """Health-check endpoint.

    Returns ``{"status": "ok", "service": "self-healing-sre-pipeline"}``
    and emits a ``health.check`` span for observability.
    """
    with tracer.start_as_current_span("health.check") as span:
        span.set_attribute("agent.persona", "task_runner")
        span.set_attribute("token.cost.accumulated", 0.0)
        span.set_attribute("dread.level", 0)
        return {"status": "ok", "service": "self-healing-sre-pipeline"}


@app.post("/pipeline/run")
async def run(task: PipelineTask) -> dict[str, Any]:
    """Execute one pipeline task and return a summary dict."""
    return await run_pipeline(task)


@app.get("/pipeline/stats")
async def stats() -> dict[str, int | float]:
    """Expose the current in-memory pipeline counters."""
    async with _stats_lock:
        return dict(_stats)


# ============================================================================
# 10.  Entry Point
# ============================================================================

if __name__ == "__main__":
    import uvicorn

    # Port 8080 avoids conflict with signoz-mcp-server (Docker :8000).
    # Override via APP_PORT env var if a different port is needed.
    _port = int(os.environ.get("APP_PORT", "8080"))

    uvicorn.run(
        "app:app",
        host="0.0.0.0",
        port=_port,
        log_level="info",
        reload=False,
    )
