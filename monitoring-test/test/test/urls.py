"""
URL configuration for test project.

The `urlpatterns` list routes URLs to views. For more information please see:
    https://docs.djangoproject.com/en/6.0/topics/http/urls/
Examples:
Function views
    1. Add an import:  from my_app import views
    2. Add a URL to urlpatterns:  path('', views.home, name='home')
Class-based views
    1. Add an import:  from other_app.views import Home
    2. Add a URL to urlpatterns:  path('', Home.as_view(), name='home')
Including another URLconf
    1. Import the include() function: from django.urls import include, path
    2. Add a URL to urlpatterns:  path('blog/', include('blog.urls'))
"""

from django.contrib import admin
from django.urls import path
from django.http import HttpResponse
from . import api_views


def metrics(request):
    from prometheus_client import generate_latest, CONTENT_TYPE_LATEST

    return HttpResponse(generate_latest(), content_type=CONTENT_TYPE_LATEST)


urlpatterns = [
    path("admin/", admin.site.urls),
    path("metrics/", metrics, name="metrics"),
    path("api/db/", api_views.db_write_read, name="db_write_read"),
    path("api/503/", api_views.service_unavailable, name="service_unavailable"),
    path("api/200/", api_views.success_response, name="success_response"),
    path("api/traceback/", api_views.traceback_error, name="traceback_error"),
]
