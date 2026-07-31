# openhost-jupyter

JupyterLab multi-language notebook environment, packaged for OpenHost.

Ships a full JupyterLab web IDE (notebook editor, file browser,
terminals, text editors) with two language kernels baked in:

- Python 3 (ipykernel) — the default kernel
- OCaml (ocaml-jupyter)

Additional kernels can be installed at runtime and persist across
restarts (see "Adding more kernels" below).

## Auth model

The OpenHost zone owner is auto-signed-in; anonymous visitors are
rejected.

- The OpenHost router verifies the owner's `zone_auth` cookie and
  stamps `X-OpenHost-Is-Owner: true` on the upstream request.
- An nginx front proxy (`:8080`) sees the owner header on the first
  top-level HTML navigation, and — if no Jupyter cookie is present
  yet — 302-redirects to `/lab?token=<TOKEN>`. Jupyter validates the
  token, mints its own `_xsrf` cookie, and the owner lands in
  JupyterLab authenticated. Subsequent requests carry the cookie, so
  the redirect fires only once.
- Anonymous (non-owner) visitors never receive the token, so
  Jupyter's own token auth rejects them. There are no public paths —
  a live kernel is arbitrary code execution, so the whole app is
  owner-only.

The Jupyter token is generated fresh on every container boot and
lives only in the process environment and the root-owned templated
nginx config under `/run`. It is **never** written under
`$OPENHOST_APP_DATA_DIR`, so apps with `access_all_data` (e.g.
file-browser) cannot read a usable credential.

## Architecture

```
browser
  -> OpenHost router (subdomain jupyter.<zone>; owner zone_auth ->
     X-OpenHost-Is-Owner: true)
  -> container :8080   nginx front proxy (WebSocket-aware)
  -> 127.0.0.1:8888    JupyterLab
```

nginx is used (rather than a pure-HTTP Python sidecar) because
Jupyter's kernels and terminals communicate over WebSockets, which
nginx proxies natively. The OpenHost router itself already forwards
WebSocket upgrades to the app port.

## Persistence

Everything under `/data/app_data/jupyter/`:

- `notebooks/` — the JupyterLab working directory (your files)
- `jupyter-data/` — `JUPYTER_DATA_DIR`: kernelspecs (including any you
  install at runtime) + runtime state
- `jupyter-config/`, `jupyter-runtime/` — Jupyter config/runtime dirs

## Adding more kernels

Open a terminal in JupyterLab (File -> New -> Terminal) and install a
kernel. The kernelspec is written under `JUPYTER_DATA_DIR`
(persistent), so it survives restarts. Examples:

- Deno (JS/TS): `deno jupyter --install` (requires deno on PATH)
- R: in R, `install.packages("IRkernel"); IRkernel::installspec()`
- Bash: `pip install bash_kernel && python -m bash_kernel.install`

Caveat: a kernel's *kernelspec* persists, but any system-level
toolchain you install with `apt-get` does **not** (the container's
root filesystem is ephemeral). For toolchains that live outside
`app_data`, install them into a persistent path or add them to the
Dockerfile. Python packages installed with `pip` into the bundled
venv also do not persist across image rebuilds; for durable Python
deps, add them to the Dockerfile.

## Resources

Defaults to 2 GiB RAM / 1 vCPU. Each running kernel is a live
process; increase `resources` in `openhost.toml` if you run many
kernels or memory-heavy notebooks.

## Files

- `Dockerfile` — Debian base + JupyterLab (venv) + OCaml/opam kernel
- `openhost.toml` — OpenHost app manifest
- `start.sh` — supervisor: generates the per-boot token, templates
  nginx.conf, launches nginx + JupyterLab
- `nginx.conf.tmpl` — nginx front-proxy template (token substituted
  at boot)
- `proxy_common.conf` — shared nginx proxy directives (WebSocket +
  header forwarding)
