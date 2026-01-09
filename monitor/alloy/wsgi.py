import os
from django.core.wsgi import get_wsgi_application

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "alloy.settings")

try:
    from observability.otel_logs import setup_logging
    from observability.otel_traces import setup_tracing

    setup_logging()
    setup_tracing()

    import logging

    logging.getLogger(__name__).info("OpenTelemetry initialized successfully")
except Exception as e:
    import traceback

    print(f"OpenTelemetry setup failed: {e}")
    traceback.print_exc()

application = get_wsgi_application()
