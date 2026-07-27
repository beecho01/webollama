FROM python:3.13-slim

# Build arg: whether to install Ollama CLI inside the container
# Set --build-arg INSTALL_OLLAMA_CLI=false to skip (smaller image)
ARG INSTALL_OLLAMA_CLI=true

WORKDIR /app

# Install system dependencies
# - curl, ca-certificates: for downloading Ollama CLI
# - procps: for `ps` etc inside the terminal
# - zstd: required by Ollama installer
# - docker-cli: for Docker exec terminal mode (optional, only useful if Docker socket is mounted)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl ca-certificates procps zstd docker.io && \
    rm -rf /var/lib/apt/lists/*

# Conditionally install Ollama CLI
RUN if [ "${INSTALL_OLLAMA_CLI}" = "true" ]; then \
        curl -fsSL https://ollama.com/install.sh | sh; \
    fi

# Upgrade pip to latest to reduce supply-chain risk
RUN pip install --no-cache-dir --upgrade pip

# Install dependencies before copying app code (better layer caching)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Create a non-root user before copying files so ownership is correct
RUN useradd -m appuser

# Copy application code (ensure .dockerignore excludes .env, .git, etc.)
COPY --chown=appuser:appuser . .

USER appuser

# Set environment variables
ENV FLASK_APP=app.py \
    PYTHONUNBUFFERED=1 \
    OLLAMA_HOST=http://ollama:11434 \
    # Terminal defaults
    WEBOLLAMA_TERMINAL_SHELL=/bin/bash \
    WEBOLLAMA_TERMINAL_PROMPT=\\u@webollama:\\w$ \
    WEBOLLAMA_TERMINAL_AUTH= \
    WEBOLLAMA_TERMINAL_MODE=local \
    WEBOLLAMA_TERMINAL_DOCKER_CONTAINER= \
    WEBOLLAMA_TERMINAL_DOCKER_SHELL=/bin/bash

# Expose the port
EXPOSE 5000

# Health check so Docker/orchestrators can detect crashes
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:5000/')"

# Start with gunicorn (gevent worker for async support)
# Uses flask-sock's built-in simple-websocket (no permessage-deflate compression)
# This avoids "Invalid frame header" errors when behind Cloudflare or other reverse proxies
# Falls back to Flask dev server if gunicorn is unavailable
CMD ["sh", "-c", "gunicorn --worker-class gevent --workers 1 --bind 0.0.0.0:5000 --access-logfile - app:app || python app.py"]