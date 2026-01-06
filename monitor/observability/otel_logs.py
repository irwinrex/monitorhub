# observability/otel_logs.py
import os

# Disable ALL resource detectors
os.environ["OTEL_RESOURCE_ATTRIBUTES"] = ""
os.environ["OTEL_PYTHON_AUTOLOAD_ENABLED"] = "false"
import atexit
import logging
from opentelemetry._logs import LogRecord
from opentelemetry.sdk._logs import (
    LoggerProvider,
    LoggingHandler,
    LogRecordProcessor,
)
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter


class CleanProcessor(BatchLogRecordProcessor):
    def emit(self, log_record: LogRecord):
        log_record.instrumentation_scope = None

        # remove PII fields
        if hasattr(log_record, "attributes") and log_record.attributes:
            log_record.attributes = {
                k: v
                for k, v in log_record.attributes.items()
                if not any(
                    s in k.lower()
                    for s in ("authorization", "cookie", "password", "email")
                )
            }

        super().emit(log_record)


def setup_logging():
    try:
        endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "grafana-alloy:4317")

        insecure = os.getenv("OTEL_EXPORTER_OTLP_INSECURE", "true").lower() == "true"

        provider = LoggerProvider()

        # --------------------------
        # gRPC EXPORTER (no HTTP)
        # --------------------------
        exporter = OTLPLogExporter(endpoint=endpoint, insecure=insecure)

        processor = CleanProcessor(
            exporter,
            max_export_batch_size=int(
                os.getenv("OTEL_BLRP_MAX_EXPORT_BATCH_SIZE", "256")
            ),
            schedule_delay_millis=int(os.getenv("OTEL_BLRP_SCHEDULE_DELAY", "3000")),
        )

        provider.add_log_record_processor(processor)

        handler = LoggingHandler(logger_provider=provider)

        level = getattr(logging, os.getenv("LOG_LEVEL", "INFO").upper(), logging.INFO)
        handler.setLevel(level)

        root = logging.getLogger()
        root.addHandler(handler)
        root.setLevel(level)

        atexit.register(lambda: provider.shutdown())

        print(f"OTEL gRPC log exporter configured → {endpoint}")
        return provider

    except Exception as e:
        print("Failed to setup OTEL logging:", e)
        return None
