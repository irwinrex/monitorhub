# Use the official Python 3.12 slim image
FROM python:3.12-slim

# Set environment variables
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

# Install system dependencies required for MySQL/MariaDB drivers
RUN apt-get update && apt-get install -y \
    pkg-config \
    default-libmysqlclient-dev \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Create a custom group and user with ID 1001
# -g 1001: Set Group ID
# -u 1001: Set User ID
# -m: Create home directory (useful for caches/configs)
RUN groupadd -g 1001 appgroup && \
    useradd -u 1001 -g appgroup -m -s /bin/bash appuser

# Set work directory
WORKDIR /app

# Install Python dependencies as root (globally)
# This allows all users to read them, but the app user cannot modify them (secure)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy project files and set ownership to 1001 immediately
# This avoids creating a duplicate filesystem layer
COPY --chown=1001:1001 . /app

# Switch to the non-root user
# Using the numeric ID (1001) is often preferred by Kubernetes/Security policies
USER 1001

# Default Run Server
CMD ["python", "manage.py", "runserver", "0.0.0.0:8000"]
