from django.http import JsonResponse, HttpResponseRedirect
import time
import logging
from opentelemetry import trace

logger = logging.getLogger(__name__)
tracer = trace.get_tracer(__name__)


def health(request):
    """Simple health endpoint with trace context."""
    with tracer.start_as_current_span("health_check"):
        logger.info("Health check endpoint hit")
        return JsonResponse({"status": "ok"})


def slow_api(request):
    """Example API with simulated latency for tracing."""
    with tracer.start_as_current_span("slow_api"):
        logger.info("Slow API called, simulating latency")
        time.sleep(0.5)
        return JsonResponse({"message": "Response after delay"})


def redirect_api(request):
    """3XX redirect example."""
    with tracer.start_as_current_span("redirect_api"):
        logger.info("Redirect API hit")
        # 302 by default; explicitly use 307 if you want method preserved
        return HttpResponseRedirect("/health/", status=307)


def client_error_api(request):
    """4XX bad request example."""
    with tracer.start_as_current_span("client_error_api"):
        logger.warning("Client triggered a 4XX error")
        return JsonResponse({"error": "Invalid request"}, status=400)


def forbidden_api(request):
    """403 forbidden example."""
    with tracer.start_as_current_span("forbidden_api"):
        logger.warning("403 Forbidden triggered")
        return JsonResponse({"error": "Forbidden"}, status=403)


def server_error_api(request):
    """5XX controlled server error."""
    with tracer.start_as_current_span("server_error_api"):
        logger.error("Internal server error simulated")
        return JsonResponse({"error": "Internal server error"}, status=500)


def server_exception_api(request):
    """5XX unhandled exception (tests tracing error spans)."""
    with tracer.start_as_current_span("server_exception_api"):
        logger.error("Simulated exception crash")
        raise RuntimeError("Simulated server failure")
