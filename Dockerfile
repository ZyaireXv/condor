# syntax=docker/dockerfile:1
FROM node:22-bookworm-slim AS frontend
WORKDIR /src/frontend
COPY frontend/package.json frontend/package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci
COPY frontend/ ./
RUN npm run build

FROM python:3.12-slim-bookworm AS dependencies
COPY --from=ghcr.io/astral-sh/uv:0.13.0 /uv /usr/local/bin/uv
ENV UV_LINK_MODE=copy UV_PYTHON_DOWNLOADS=never
WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-dev --no-install-project

FROM python:3.12-slim-bookworm AS runtime
ARG SOURCE_URL=https://github.com/ZyaireXv/condor
ARG VCS_REF=unknown
LABEL org.opencontainers.image.title="Condor" \
      org.opencontainers.image.description="Condor dashboard and Python backend" \
      org.opencontainers.image.source=$SOURCE_URL \
      org.opencontainers.image.revision=$VCS_REF \
      org.opencontainers.image.licenses="MIT"
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates chromium ffmpeg git libgomp1 tini \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 condor \
    && useradd --uid 10001 --gid condor --create-home condor
COPY --from=dependencies /usr/local/bin/uv /usr/local/bin/uv
WORKDIR /app
COPY --from=dependencies --chown=condor:condor /app/.venv /app/.venv
COPY --chown=condor:condor main.py config_manager.py pyproject.toml uv.lock LICENSE ./
COPY --chown=condor:condor condor/ ./condor/
COPY --chown=condor:condor handlers/ ./handlers/
COPY --chown=condor:condor utils/ ./utils/
COPY --chown=condor:condor mcp_servers/ ./mcp_servers/
COPY --chown=condor:condor routines/ ./routines/
COPY --chown=condor:condor agents/ ./agents/
COPY --from=frontend --chown=condor:condor /src/frontend/dist ./frontend/dist
# Native ConfigManager writes config, backup and audit files beside main.py.
# Symlinks keep all three in the persistent data volume without changing it.
RUN mkdir -p /app/data /app/.condor /app/reports \
    && ln -s /app/data/config.yml /app/config.yml \
    && ln -s /app/data/config.yml.bak /app/config.yml.bak \
    && ln -s /app/data/audit_log.yml /app/audit_log.yml \
    && chown -R condor:condor /app /home/condor
ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 \
    UV_PYTHON_DOWNLOADS=never UV_LINK_MODE=copy \
    WEB_HOST=0.0.0.0 WEB_PORT=8088 CONDOR_MODE=telegram \
    CONDOR_DATA_DIR=/app/data CONDOR_RUNTIME_ROOT=/app/.condor \
    CONDOR_REPORTS_DIR=/app/reports BROWSER_PATH=/usr/bin/chromium
USER condor
EXPOSE 8088
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
    CMD python -c "import urllib.request; from utils.config import WEB_PORT; urllib.request.urlopen(f'http://127.0.0.1:{WEB_PORT}/api/v1/auth/mode', timeout=3)" || exit 1
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["python", "main.py"]
