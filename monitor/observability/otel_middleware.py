# observability/otel_middleware.py
import logging
import time
from django.utils.deprecation import MiddlewareMixin

from observability.otel_metrics import setup_metrics, record_request

logger = logging.getLogger(__name__)

_metrics_objs = setup_metrics()
_counter = _metrics_objs["counter"]
_histogram = _metrics_objs["histogram"]

class SmartLoggingMiddleware(MiddlewareMixin):
    """
    Middleware that logs requests/responses and also records metrics:
      - counts by status class (2xx,4xx,5xx)
      - latency histogram
    """
    
    def __init__(self, get_response):
        self.get_response = get_response
        super().__init__(get_response)

    def should_log(self, path):
        """Determine if we should log/record this request"""
        excluded_paths = ['/favicon.ico', '/static/', '/admin/']
        return not any(path.startswith(excluded) for excluded in excluded_paths)

    def get_severity_by_status(self, status_code):
        if status_code >= 500:
            return "ERROR"
        elif status_code >= 400:
            return "WARNING"
        else:
            return "INFO"

    def process_request(self, request):
        if not self.should_log(request.path):
            return None
        
        request._start_time = time.time()
        logger.info(
            f"→ {request.method} {request.path}",
            extra={
                "http.method": request.method,
                "http.route": request.path,
                "http.url": request.build_absolute_uri()[:500],
                "http.user_agent": request.META.get('HTTP_USER_AGENT', '')[:200],
                "http.client_ip": self.get_client_ip(request),
                "log.type": "request"
            }
        )
        return None

    def process_response(self, request, response):
        if not self.should_log(request.path):
            return response

        duration = 0.0
        if hasattr(request, '_start_time'):
            duration = time.time() - request._start_time

        status_code = response.status_code
        severity = self.get_severity_by_status(status_code)
        log_method = getattr(logger, severity.lower())

        log_method(
            f"← {request.method} {request.path} - {status_code} ({duration*1000:.0f}ms)",
            extra={
                "http.method": request.method,
                "http.route": request.path,
                "http.status_code": status_code,
                "http.duration_ms": round(duration*1000, 2),
                "http.response_size": len(response.content) if hasattr(response, 'content') else 0,
                "log.type": "response",
                "log.severity": severity
            }
        )

        # Record metrics: convert duration to seconds
        record_request(
            _counter,
            _histogram,
            status_code=status_code,
            method=request.method,
            route=request.path,
            duration_s=duration
        )

        return response

    def process_exception(self, request, exception):
        if not self.should_log(request.path):
            return None

        logger.error(
            f"✗ {request.method} {request.path} - {exception.__class__.__name__}",
            extra={
                "http.method": request.method,
                "http.route": request.path,
                "http.url": request.build_absolute_uri()[:500],
                "error.message": str(exception)[:500],
                "error.type": exception.__class__.__name__,
                "log.type": "exception",
                "log.severity": "ERROR"
            },
            exc_info=True
        )
        return None

    def get_client_ip(self, request):
        x_forwarded_for = request.META.get('HTTP_X_FORWARDED_FOR')
        if x_forwarded_for:
            ip = x_forwarded_for.split(',')[0]
        else:
            ip = request.META.get('REMOTE_ADDR', 'unknown')
        return ip
