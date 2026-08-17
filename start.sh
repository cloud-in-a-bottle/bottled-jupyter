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
# Auth flow on an owner visit:
#   1. Owner GETs any page on jupyter.<zone>.  The router stamps
#      X-OpenHost-Is-Owner: true.
#   2. If that navigation has no Jupyter session cookie, nginx 302s it
#      to the same URL with ?token=<TOKEN> appended.
#   3. Jupyter validates the token, mints its own session + _xsrf
#      cookies, and the owner lands in JupyterLab authenticated.
#      Subsequent requests carry the cookie, so no further redirects.
#   4. If a session cookie is present but no longer valid — every
#      restart mints a new cookie_secret, since JUPYTER_RUNTIME_DIR is
#      on the ephemeral /run — Jupyter 302s the navigation to
#      /login?next=<original>, and nginx re-runs step 2 from there.
#      Jupyter honours ?token= on /login, so the owner is signed back
#      in and forwarded to where they were going without ever seeing
#      the login form (which they could not get past: the token is the
#      only credential and they never see it).
#   Anonymous (non-owner) visitors never get the token; the router
#   rejects them before the app, and Jupyter's own auth rejects them
#   after.  There are no public paths.
#
# Security note: the Jupyter token is generated fresh each boot and
# lives only in this process's environment + the (root-owned, /run)
# nginx.conf.  It is NEVER written under $OPENHOST_APP_DATA_DIR, so
# file-browser (and any other app with access_all_data) can't read a
# usable credential.  jupyter_server's own runtime connection file
# (jpserver-*.json), which also embeds the token, is written to
# JUPYTER_RUNTIME_DIR = /run/jupyter-runtime.  Both app_data AND
# app_temp_data are bind-mounted into access_all_data apps, so neither
# is safe for credentials; /run is the container's own ephemeral fs
# and is never mounted into another app.  jupyter_server's
# cookie_secret_file defaults to JUPYTER_RUNTIME_DIR too, so it is
# likewise unreadable from other apps — at the cost of a new
# cookie_secret each boot, which the auto-login flow above absorbs.

set -euo pipefail

PERSIST="${OPENHOST_APP_DATA_DIR:-/data/app_data/jupyter}"
NB_USER="jovyan"
NB_UID="$(id -u "$NB_USER")"
NB_GID="$(id -g "$NB_USER")"

NOTEBOOK_DIR="$PERSIST/notebooks"
JUPYTER_DATA="$PERSIST/jupyter-data"
JUPYTER_CONFIG="$PERSIST/jupyter-config"
# Runtime dir holds jupyter_server's jpserver-<pid>.json, which embeds
# the live auth token in plaintext.  It MUST NOT live under app_data
# OR app_temp_data: BOTH of those tiers are bind-mounted (read/write)
# into any app with access_all_data (e.g. file-browser), so neither
# provides credential isolation.  /run is the container's own
# ephemeral filesystem — never bind-mounted out — so a live token
# there is invisible to other apps.
JUPYTER_RUNTIME="/run/jupyter-runtime"

# Clean up any credential-bearing artifacts from earlier iterations of
# this app that may have been written under app_data (defence in
# depth; we never write them there now).  This includes any legacy
# jupyter-runtime dir a prior version placed under $PERSIST.
rm -f "$PERSIST/jupyter-token.txt" "$PERSIST/token" 2>/dev/null || true
rm -rf "$PERSIST/jupyter-runtime" 2>/dev/null || true

mkdir -p "$NOTEBOOK_DIR" "$JUPYTER_DATA" "$JUPYTER_CONFIG" "$JUPYTER_RUNTIME"

# The bind-mounted dirs are owned by root on first boot; hand them to
# the notebook user so JupyterLab (and runtime pip/opam kernel
# installs) can write to them.
chown -R "$NB_UID:$NB_GID" "$PERSIST" 2>/dev/null || true
chown -R "$NB_UID:$NB_GID" "$JUPYTER_RUNTIME" 2>/dev/null || true

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
