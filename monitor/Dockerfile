FROM python:3.11-slim

# Set the working directory
WORKDIR /app

# Install system dependencies
RUN set -ex \
  && apt-get update \
  && apt-get upgrade -y \
  && apt-get install -y --no-install-recommends \
  pkg-config \
  libmariadb-dev-compat \
  gcc \
  libmariadb-dev \
  libxml2-dev \
  libssl-dev \
  curl \
  && apt-get autoremove -y \
  && apt-get clean -y \
  && rm -rf /var/lib/apt/lists/*

# Upgrade pip
RUN pip install --upgrade pip

# Copy requirements and install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY . /app

# Create non-root user for security
# RUN addgroup --system python && adduser --system --group python \
#   && chown -R python:python /app

# Switch to non-root user
# USER python

# Expose Django development server port
EXPOSE 8000

# Start Django development server (or use uwsgi for production-like setup)
CMD ["python", "manage.py", "runserver", "0.0.0.0:8000"]
