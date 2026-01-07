
FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# System deps (minimal, prod-safe)
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates \
       curl \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN addgroup --system django \
    && adduser --system --ingroup django django

WORKDIR /app

# Copy dependency list first (layer cache)
COPY monitoring/requirements.txt .

RUN pip install --upgrade pip \
    && pip install -r requirements.txt

# Copy project
COPY monitoring/ monitoring/

# Permissions
RUN chown -R django:django /app

USER django

EXPOSE 8000

