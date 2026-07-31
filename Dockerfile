# JupyterLab multi-language notebook environment, packaged for OpenHost.
#
# Layout inside the container:
#
#   /opt/openhost-jupyter/
#     start.sh        — supervises nginx + JupyterLab; generates the
#                       per-boot Jupyter token; templates nginx.conf.
#     nginx.conf.tmpl — nginx front-proxy template (WebSocket-aware);
#                       __JUPYTER_TOKEN__ is substituted at boot.
#
# Kernels baked in:
#   * Python 3   — ipykernel (default kernel)
#   * OCaml      — ocaml-jupyter (installed via opam)
#
# Topology:
#   browser
#     -> OpenHost router (subdomain jupyter.<zone>; verifies owner
#        zone_auth, stamps X-OpenHost-Is-Owner: true)
#     -> container :8080          (nginx front proxy, WS-aware)
#     -> 127.0.0.1:8888           (JupyterLab)
#
# The OpenHost router itself proxies WebSockets to :8080, and nginx
# proxies them onward to Jupyter's :8888 kernel/terminal sockets.

FROM docker.io/library/debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PYTHONUNBUFFERED=1 \
    OPAMROOT=/opt/opam \
    OPAMYES=1

# ---------------------------------------------------------------------------
# System packages
# ---------------------------------------------------------------------------
#   python3 / pip / venv  — JupyterLab + ipykernel runtime
#   nginx                 — WebSocket-aware front proxy on :8080
#   gosu                  — drop privileges to the notebook user
#   tini                  — PID 1 reaper / signal forwarder
#   opam + ocaml + build  — OCaml kernel toolchain
#   libzmq3-dev, pkg-config, m4, libgmp-dev — ocaml-jupyter build deps
#   curl, ca-certificates — readiness probes + TLS roots
RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends \
        python3 \
        python3-pip \
        python3-venv \
        python3-dev \
        nginx \
        gosu \
        tini \
        curl \
        ca-certificates \
        bubblewrap \
        opam \
        ocaml \
        build-essential \
        m4 \
        pkg-config \
        libzmq3-dev \
        libgmp-dev \
        zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Unprivileged runtime user
# ---------------------------------------------------------------------------
# JupyterLab runs as this user.  Its home holds the opam switch and
# the default (build-time) Jupyter data dir; at runtime start.sh
# points JUPYTER_DATA_DIR at the persistent app_data dir so
# owner-installed kernelspecs survive restarts.
RUN useradd --create-home --home-dir /home/jovyan --shell /bin/bash --uid 1000 jovyan

# ---------------------------------------------------------------------------
# JupyterLab (Python)
# ---------------------------------------------------------------------------
# Installed into a venv owned by the notebook user so runtime
# `pip install` works without root.
ENV VIRTUAL_ENV=/opt/venv
RUN python3 -m venv "$VIRTUAL_ENV" \
 && "$VIRTUAL_ENV/bin/pip" install --no-cache-dir --upgrade pip \
 && "$VIRTUAL_ENV/bin/pip" install --no-cache-dir \
        jupyterlab==4.6.2 \
        ipykernel==6.30.1 \
 && "$VIRTUAL_ENV/bin/python" -m ipykernel install --sys-prefix \
        --name python3 --display-name "Python 3" \
 && chown -R jovyan:jovyan "$VIRTUAL_ENV"
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

# ---------------------------------------------------------------------------
# OCaml kernel (ocaml-jupyter) via opam
# ---------------------------------------------------------------------------
# Built as the notebook user so the opam switch is user-owned and
# writable at runtime.  The kernelspec is installed system-wide
# (--prefix into the venv) so JupyterLab discovers it.
RUN mkdir -p "$OPAMROOT" && chown -R jovyan:jovyan "$OPAMROOT"
USER jovyan
# ocaml-jupyter-opam-genspec bakes "-init <HOME>/.ocamlinit" into the
# kernelspec; running as jovyan makes that /home/jovyan/.ocamlinit.
# Ensure the file exists so the kernel doesn't warn on a missing init.
RUN touch /home/jovyan/.ocamlinit
RUN opam init --bare --disable-sandboxing --no-setup -y \
 && opam switch create default ocaml-base-compiler.4.14.2 -y \
 && eval "$(opam env --switch=default)" \
 && opam install -y jupyter \
 && eval "$(opam env --switch=default)" \
 && ocaml-jupyter-opam-genspec \
 && "$VIRTUAL_ENV/bin/jupyter" kernelspec install --sys-prefix --name ocaml-jupyter \
        "$OPAMROOT/default/share/jupyter" \
 && opam clean -a
USER root

# ---------------------------------------------------------------------------
# App files
# ---------------------------------------------------------------------------
COPY start.sh          /opt/openhost-jupyter/start.sh
COPY nginx.conf.tmpl   /opt/openhost-jupyter/nginx.conf.tmpl
COPY proxy_common.conf /opt/openhost-jupyter/proxy_common.conf
RUN chmod 0755 /opt/openhost-jupyter/start.sh

# OpenHost-routed port (nginx front proxy).  Jupyter's own port
# (8888) remains loopback-only.
EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/openhost-jupyter/start.sh"]
