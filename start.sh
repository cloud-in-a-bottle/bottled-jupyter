#!/bin/bash
# Boot JupyterLab + nginx front proxy for OpenHost.
#
# Topology:
#   browser
#     -> OpenHost router (subdomain jupyter.<zone>; verifies owner
#        zone_auth, stamps X-OpenHost-Is-Owner: true)
#     -> container :8080          (nginx, WebSocket-aware)
#     -> 127.0.0.1:8888           (JupyterLab)
#
# Auth flow on first owner visit:
#   1. Owner GETs / on jupyter.<zone>.  Router stamps
#      X-OpenHost-Is-Owner: true.
#   2. nginx sees owner + HTML nav + no Jupyter cookie and 302s to
#      /lab?token=<TOKEN>.
#   3. Jupyter validates the token, mints its own _xsrf cookie, and
#      the owner lands in JupyterLab authenticated.  Subsequent
#      requests carry the cookie, so the token redirect doesn't fire
#      again.
#   Anonymous (non-owner) visitors never get the token; Jupyter's own
#   auth rejects them.  There are no public paths.
#
# Security note: the Jupyter token is generated fresh each boot and
# lives only in this process's environment + the (root-owned, /run)
# nginx.conf.  It is NEVER written under $OPENHOST_APP_DATA_DIR, so
# file-browser (and any other app with access_all_data) can't read a
# usable credential.

set -euo pipefail

PERSIST="${OPENHOST_APP_DATA_DIR:-/data/app_data/jupyter}"
NB_USER="jovyan"
NB_UID="$(id -u "$NB_USER")"
NB_GID="$(id -g "$NB_USER")"

NOTEBOOK_DIR="$PERSIST/notebooks"
JUPYTER_DATA="$PERSIST/jupyter-data"
JUPYTER_CONFIG="$PERSIST/jupyter-config"
JUPYTER_RUNTIME="$PERSIST/jupyter-runtime"

# Clean up any stale credential file from earlier iterations of this
# app (defence in depth; we never write one now).
rm -f "$PERSIST/jupyter-token.txt" "$PERSIST/token" 2>/dev/null || true

mkdir -p "$NOTEBOOK_DIR" "$JUPYTER_DATA" "$JUPYTER_CONFIG" "$JUPYTER_RUNTIME"

# The bind-mounted persistent dir is owned by root on first boot;
# hand it to the notebook user so JupyterLab (and runtime pip/opam
# kernel installs) can write to it.
chown -R "$NB_UID:$NB_GID" "$PERSIST" 2>/dev/null || true

# nginx scratch dirs (all under /tmp per nginx.conf.tmpl).
mkdir -p /tmp/nginx-client-body /tmp/nginx-proxy /tmp/nginx-fastcgi \
         /tmp/nginx-uwsgi /tmp/nginx-scgi

# ---------------------------------------------------------------------------
# Generate the per-boot Jupyter token and template nginx.conf.
# ---------------------------------------------------------------------------
JUPYTER_TOKEN="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"

NGINX_CONF="/run/openhost-jupyter-nginx.conf"
# Substitute the token into the nginx template.  Use a Python
# replace (not sed) so token characters ('/', '&', etc. from
# token_urlsafe are '-'/'_' only, but be safe) never break the
# substitution.
JUPYTER_TOKEN="$JUPYTER_TOKEN" python3 - "$NGINX_CONF" <<'PY'
import os
import sys

dest = sys.argv[1]
with open("/opt/openhost-jupyter/nginx.conf.tmpl", encoding="utf-8") as fh:
    conf = fh.read()
conf = conf.replace("__JUPYTER_TOKEN__", os.environ["JUPYTER_TOKEN"])
with open(dest, "w", encoding="utf-8") as fh:
    fh.write(conf)
PY

# ---------------------------------------------------------------------------
# Launch nginx first so /_healthz answers 200 within the 60s
# OpenHost cold-start grace window.
# ---------------------------------------------------------------------------
echo "[start.sh] Starting nginx front proxy on :8080"
nginx -c "$NGINX_CONF" -g 'daemon off;' &
NGINX_PID=$!

# ---------------------------------------------------------------------------
# Launch JupyterLab as the notebook user.
# ---------------------------------------------------------------------------
# * JUPYTER_DATA_DIR under app_data => owner-installed kernelspecs
#   persist across restarts.
# * ServerApp.token carries our per-boot token.
# * allow_remote_access + disabled host-check: the router strips Host
#   (Jupyter sees 127.0.0.1), and we forward X-Forwarded-Host; Jupyter
#   must not reject the mismatch.
# * base_url "/" and trust_xheaders so redirects/links use the
#   external host.
echo "[start.sh] Starting JupyterLab on 127.0.0.1:8888"
export JUPYTER_DATA_DIR="$JUPYTER_DATA"
export JUPYTER_CONFIG_DIR="$JUPYTER_CONFIG"
export JUPYTER_RUNTIME_DIR="$JUPYTER_RUNTIME"
export OPAMROOT="${OPAMROOT:-/opt/opam}"

gosu "$NB_USER" env \
    JUPYTER_DATA_DIR="$JUPYTER_DATA" \
    JUPYTER_CONFIG_DIR="$JUPYTER_CONFIG" \
    JUPYTER_RUNTIME_DIR="$JUPYTER_RUNTIME" \
    OPAMROOT="$OPAMROOT" \
    PATH="/opt/venv/bin:$PATH" \
    /opt/venv/bin/jupyter lab \
        --ip=127.0.0.1 \
        --port=8888 \
        --no-browser \
        --notebook-dir="$NOTEBOOK_DIR" \
        --ServerApp.token="$JUPYTER_TOKEN" \
        --ServerApp.password="" \
        --ServerApp.base_url="/" \
        --ServerApp.allow_remote_access=True \
        --ServerApp.trust_xheaders=True \
        --ServerApp.allow_origin="*" \
        --ServerApp.disable_check_xsrf=False \
        --ServerApp.tornado_settings="{\"headers\": {}}" \
        --ServerApp.terminals_enabled=True \
    &
JUPYTER_PID=$!

# ---------------------------------------------------------------------------
# Supervision: if either process dies, tear the other down and exit.
# ---------------------------------------------------------------------------
trap 'kill -TERM "$NGINX_PID" "$JUPYTER_PID" 2>/dev/null; wait' TERM INT

set +e
wait -n "$NGINX_PID" "$JUPYTER_PID"
EXIT_CODE=$?
set -e

echo "[start.sh] Child exited (code=$EXIT_CODE); shutting down"
kill -TERM "$NGINX_PID" "$JUPYTER_PID" 2>/dev/null || true
wait || true
exit "$EXIT_CODE"
