# bottled-jupyter

JupyterLab multi-language notebook environment, packaged for Cloud in a Bottle.

Ships a full JupyterLab web IDE (notebook editor, file browser,
terminals, text editors) with two language kernels baked in:

- Python 3 (ipykernel) — the default kernel
- OCaml (ocaml-jupyter)

Additional kernels can be installed at runtime and persist across
restarts (see "Adding more kernels" below).

## Auth model

The Cloud in a Bottle zone owner is auto-signed-in; anonymous visitors are
rejected.

- The Cloud in a Bottle router verifies the owner's session and stamps
  `X-OpenHost-Is-Owner: true` on the upstream request (it strips any
  client-supplied `X-OpenHost-*` header first, so it can't be forged).
- An nginx front proxy (`:8080`) watches for owner HTML navigations:
  - no Jupyter session cookie yet → 302 to the same URL with
    `?token=<TOKEN>` appended, so Jupyter authenticates the request and
    mints its own session cookie;
  - a navigation that lands on `/login` (Jupyter's redirect target for
    anything it considers unauthenticated) → 302 to `/login` with the
    token appended, which signs the owner in and forwards them to the
    page they asked for.
- Anonymous (non-owner) visitors never receive the token, so
  Jupyter's own token auth rejects them. There are no public paths —
  a live kernel is arbitrary code execution, so the whole app is
  owner-only.

The `/login` rule is what makes this robust. Jupyter's login form is a
dead end for the owner — the per-boot token is the only credential and
they never see it — so the proxy has to keep them off it in every case,
including the ones a cookie check can't detect:

- a bookmark or restored tab pointing at a deep link;
- a session cookie that is still in the browser but no longer valid.
  That is the normal state after any restart: `jupyter_server` keeps its
  `cookie_secret` in `JUPYTER_RUNTIME_DIR`, which we deliberately place
  on the container's ephemeral `/run` (see below), so every boot
  invalidates every session cookie already handed out.

Note that the `_xsrf` cookie is deliberately *not* treated as a sign-in
marker: Jupyter hands one out to anonymous visitors when it renders the
login page. An earlier version of this app used it as one, which meant a
single glimpse of the login page — or one restart — suppressed
auto-login from then on and left the owner stuck on a login form with
nothing to type into it.

One consequence of auto-login: JupyterLab's "Log Out" only ends the
Jupyter session, not the zone session, so the next navigation signs the
owner straight back in. Zone-level logout is the real logout.

The Jupyter token is generated fresh on every container boot and
lives only in the process environment and the root-owned templated
nginx config under `/run`. It is **never** written under
`$OPENHOST_APP_DATA_DIR`, so apps with `access_all_data` (e.g.
file-browser) cannot read a usable credential.

Note that `jupyter_server` writes its runtime connection file
(`jpserver-*.json`), which also contains the live token, into
`JUPYTER_RUNTIME_DIR`. We point that at `/run/jupyter-runtime` — the
container's own ephemeral filesystem, never bind-mounted into another
app. (Both `app_data` and `app_temp_data` are mounted into apps with
`access_all_data`, so neither is a safe place for a live token.)
`cookie_secret_file` defaults into the same directory, which is why
sessions don't survive a restart; the `/login` rule above makes that
invisible.

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
nginx proxies natively. The Cloud in a Bottle router itself already forwards
WebSocket upgrades to the app port.

## Persistence

Everything under `/data/app_data/jupyter/`:

- `notebooks/` — the JupyterLab working directory (your files)
- `jupyter-data/` — `JUPYTER_DATA_DIR`: kernelspecs (including any you
  install at runtime)
- `jupyter-config/` — `JUPYTER_CONFIG_DIR`

The Jupyter runtime dir (`JUPYTER_RUNTIME_DIR`) is deliberately kept
off `app_data` — see the auth-model note above.

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
- `openhost.toml` — Cloud in a Bottle app manifest
- `start.sh` — supervisor: generates the per-boot token, templates
  nginx.conf, launches nginx + JupyterLab
- `nginx.conf.tmpl` — nginx front-proxy template (token substituted
  at boot)
- `proxy_common.conf` — shared nginx proxy directives (WebSocket +
  header forwarding)
- `tests/autologin_matrix.sh` — runs the real proxy config in front of a
  jupyter_server stub and asserts the owner never lands on the login
  form (needs nginx, python3, curl; run it after touching either conf)
