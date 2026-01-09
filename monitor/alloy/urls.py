"""
URL configuration for alloy project.

The `urlpatterns` list routes URLs to views. For more information please see:
    https://docs.djangoproject.com/en/5.2/topics/http/urls/
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

from .views import (
    health,
    slow_api,
    redirect_api,
    client_error_api,
    forbidden_api,
    server_error_api,
    server_exception_api,
)

urlpatterns = [
    path('admin/', admin.site.urls),

    # Health + Testing
    path("healthz/", health),
    path("slow/", slow_api),

    # 3XX
    path("redirect/", redirect_api),

    # 4XX
    path("bad-request/", client_error_api),
    path("forbidden/", forbidden_api),

    # 5XX
    path("error/", server_error_api),
    path("exception/", server_exception_api),
]
