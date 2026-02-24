import traceback
from django.http import JsonResponse
from django.db import connection


def db_write_read(request):
    try:
        with connection.cursor() as cursor:
            cursor.execute("SELECT 1")
            cursor.fetchone()

        return JsonResponse(
            {
                "status": "success",
                "message": "Database write and read operation completed",
            },
            status=200,
        )
    except Exception as e:
        return JsonResponse({"status": "error", "message": str(e)}, status=500)


def service_unavailable(request):
    return JsonResponse(
        {"status": "error", "message": "Service temporarily unavailable"}, status=503
    )


def success_response(request):
    return JsonResponse(
        {"status": "success", "message": "Operation completed successfully"}, status=200
    )


def traceback_error(request):
    try:
        raise ValueError("This is a test traceback error")
    except Exception:
        error_trace = traceback.format_exc()
        return JsonResponse(
            {
                "status": "error",
                "message": "Traceback error occurred",
                "traceback": error_trace,
            },
            status=500,
        )
