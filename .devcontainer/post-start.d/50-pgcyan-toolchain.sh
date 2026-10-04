#!/bin/bash
#
# post-start step: the pg_cyan development toolchain, installed without root.
#
# The container has no sudo and apt is blocked by the firewall, so everything
# here goes into the vscode user's home via pip, a pre-built tarball and one
# small source build:
#
#   * the pg_cyan + control-plane Python requirements (user site);
#   * pgserver -- a pip-installed PostgreSQL 16 (initdb, pg_ctl, postgres, psql,
#     pg_dump, pg_restore, pg_recvlogical) that provides the two LOCAL databases
#     the end-to-end run needs, and the pg_dump/pg_restore pgcopydb shells out to;
#   * pgcopydb -- the fork binary taken from the published pgcyan image on the
#     host and dropped at tools/pgcopydb-linux-amd64.tgz. Only the binaries are
#     taken from the tarball: its libgc was built against a newer glibc than
#     this container has, so
#   * libgc (Boehm GC, pgcopydb's one runtime library the container lacks) is
#     built from the bdwgc GitHub release into ~/.local/lib. patchelf gives
#     pgcopydb an rpath so it finds that library without LD_LIBRARY_PATH.
#
# Best-effort and idempotent: a missing tarball or an offline PyPI/GitHub logs
# and skips rather than failing the container start (mirrors 30-kubeconfig.sh).

# -u: undefined vars are errors; -o pipefail: catch failures in pipelines.
# NOTE: no -e on purpose -- individual steps degrade gracefully below.
set -uo pipefail

WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PGCYAN="$WORKSPACE/projects/pgcyan"
TARBALL="$WORKSPACE/tools/pgcopydb-linux-amd64.tgz"
LOCAL="$HOME/.local"
MARKER_DIR="$HOME/.cache/pgcyan-toolchain"
BDWGC_VERSION="8.2.8"
BDWGC_URL="https://github.com/bdwgc/bdwgc/releases/download/v${BDWGC_VERSION}/gc-${BDWGC_VERSION}.tar.gz"
mkdir -p "$LOCAL/bin" "$LOCAL/lib" "$MARKER_DIR"

# ---------------------------------------------------------------- python deps
# Skipped when the requirement files have not changed since the last run, so a
# normal container start does not hit PyPI at all.
REQ_FILES=(
    "$PGCYAN/requirements.txt"
    "$PGCYAN/requirements-dev.txt"
    "$PGCYAN/control-plane/api/requirements.txt"
    "$PGCYAN/control-plane/api/requirements-dev.txt"
)
if [ -d "$PGCYAN" ]; then
    req_args=()
    for f in "${REQ_FILES[@]}"; do [ -f "$f" ] && req_args+=(-r "$f"); done
    req_hash="$(cat "${REQ_FILES[@]}" 2>/dev/null | sha256sum | cut -c1-16)"
    if [ -f "$MARKER_DIR/pip-$req_hash" ]; then
        echo "Python requirements unchanged; skipping pip."
    elif pip install -q --user "${req_args[@]}" pgserver patchelf; then
        rm -f "$MARKER_DIR"/pip-*
        touch "$MARKER_DIR/pip-$req_hash"
        echo "Installed Python requirements + pgserver + patchelf into the user site."
    else
        echo "WARN: pip install failed (PyPI unreachable?); the pg_cyan test suite may not run."
    fi
else
    echo "WARN: $PGCYAN not found; skipping Python requirements."
fi

# ------------------------------------------------------------------- pgserver
# Expose the bundled PostgreSQL 16 binaries on PATH (~/.local/bin is already on
# PATH via ~/.profile). Symlinks are enough: the binaries carry an $ORIGIN rpath
# that the kernel resolves through the link to the real location.
pg_bin="$(python3 -c 'import os, pgserver; print(os.path.join(os.path.dirname(pgserver.__file__), "pginstall", "bin"))' 2>/dev/null || true)"
if [ -n "$pg_bin" ] && [ -x "$pg_bin/postgres" ]; then
    for tool in postgres initdb pg_ctl psql pg_dump pg_dumpall pg_restore pg_recvlogical pg_isready pg_config createdb dropdb pgbench; do
        [ -x "$pg_bin/$tool" ] && ln -sfn "$pg_bin/$tool" "$LOCAL/bin/$tool"
    done
    echo "PostgreSQL client/server on PATH: $("$LOCAL/bin/postgres" --version)"
else
    echo "WARN: pgserver not importable; no local PostgreSQL available."
fi

# ------------------------------------------------------------------- pgcopydb
pgcopydb_runs() { "$LOCAL/bin/pgcopydb" --version >/dev/null 2>&1; }

if [ ! -f "$TARBALL" ]; then
    echo "No pgcopydb tarball at $TARBALL; skipping."
    echo "  (Build it on the host from the published pgcyan image -- see plans/kubernetes-independence/README.md.)"
elif [ -x "$LOCAL/bin/pgcopydb" ] && [ "$LOCAL/bin/pgcopydb" -nt "$TARBALL" ] && pgcopydb_runs; then
    echo "pgcopydb already installed: $("$LOCAL/bin/pgcopydb" --version 2>/dev/null | grep -m1 '^pgcopydb version')"
else
    # Binaries only; the tarball's lib/ is deliberately ignored (glibc mismatch).
    if tar xzf "$TARBALL" -C "$LOCAL" --no-same-owner ./bin/pgcopydb ./bin/sqlite3 2>/dev/null; then
        chmod 0755 "$LOCAL/bin/pgcopydb" "$LOCAL/bin/sqlite3" 2>/dev/null || true
        touch "$LOCAL/bin/pgcopydb"
        if command -v patchelf >/dev/null 2>&1; then
            patchelf --set-rpath '$ORIGIN/../lib' "$LOCAL/bin/pgcopydb" \
                || echo "WARN: patchelf failed; pgcopydb may need LD_LIBRARY_PATH=$LOCAL/lib."
        else
            echo "WARN: patchelf not found; pgcopydb needs LD_LIBRARY_PATH=$LOCAL/lib to run."
        fi
        echo "Unpacked pgcopydb + sqlite3 into $LOCAL/bin."
    else
        echo "WARN: could not unpack $TARBALL."
    fi

    # libgc: build from source if pgcopydb cannot load it. Takes about a
    # minute; cached in ~/.local/lib afterwards.
    if ! pgcopydb_runs; then
        build="$(mktemp -d)"
        echo "Building libgc ${BDWGC_VERSION} from ${BDWGC_URL} ..."
        if curl -sSL -m 120 -o "$build/gc.tar.gz" "$BDWGC_URL" \
           && tar xzf "$build/gc.tar.gz" -C "$build" \
           && ( cd "$build/gc-${BDWGC_VERSION}" \
                && ./configure --prefix="$LOCAL" --disable-static --enable-threads=posix --with-libatomic-ops=none >configure.log 2>&1 \
                && make -j"$(nproc)" >make.log 2>&1 \
                && make install >install.log 2>&1 ); then
            echo "Installed libgc into $LOCAL/lib."
        else
            echo "WARN: libgc build failed (GitHub unreachable or compiler error); see $build."
        fi
        [ -d "$build" ] && pgcopydb_runs && rm -rf "$build"
    fi

    if pgcopydb_runs; then
        echo "pgcopydb installed: $("$LOCAL/bin/pgcopydb" --version 2>/dev/null | grep -m1 '^pgcopydb version')"
    else
        echo "WARN: pgcopydb does not run; check shared libraries with: ldd $LOCAL/bin/pgcopydb"
    fi
fi

# ---------------------------------------------------------- azure (optional)
# Only when the host mounted the credentials file the bootstrap script prints
# (projects/pgcyan/scripts/azure/bootstrap-runtime.sh): install the Azure CLI
# from PyPI and Terraform from its release server, both without root, and
# export the variables into every shell so azure-identity, the CLI and
# Terraform all authenticate as the scoped service principal.
AZURE_ENV="/etc/pgcyan-azure.env"
TERRAFORM_VERSION="1.9.8"
if [ -f "$AZURE_ENV" ]; then
    if ! command -v az >/dev/null 2>&1; then
        echo "Installing the Azure CLI from PyPI (a few minutes, once) ..."
        pip install -q --user azure-cli && echo "Azure CLI: $(az version --query '"azure-cli"' -o tsv 2>/dev/null)" \
            || echo "WARN: the Azure CLI did not install."
    fi
    if ! command -v terraform >/dev/null 2>&1; then
        arch="$(dpkg --print-architecture)"
        base="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}"
        tmp="$(mktemp -d)"
        if curl -fsSL -o "$tmp/tf.zip" "${base}/terraform_${TERRAFORM_VERSION}_linux_${arch}.zip" \
           && curl -fsSL -o "$tmp/SHA256SUMS" "${base}/terraform_${TERRAFORM_VERSION}_SHA256SUMS" \
           && (cd "$tmp" && grep "linux_${arch}.zip" SHA256SUMS | sed 's/terraform_.*zip/tf.zip/' | sha256sum -c - >/dev/null) \
           && python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extract('terraform', sys.argv[2])" "$tmp/tf.zip" "$LOCAL/bin" \
           && chmod 0755 "$LOCAL/bin/terraform"; then
            echo "Terraform: $("$LOCAL/bin/terraform" version | head -1)"
        else
            echo "WARN: Terraform ${TERRAFORM_VERSION} did not install (releases.hashicorp.com unreachable?)."
        fi
        rm -rf "$tmp"
    fi
    # Export the credentials in login shells, once (the marker keeps it idempotent).
    marker="# pgcyan-azure-env"
    if ! grep -qF "$marker" "$HOME/.bashrc" 2>/dev/null; then
        {
            echo "$marker"
            echo "if [ -f $AZURE_ENV ]; then set -a; . $AZURE_ENV; set +a; export CHECKPOINT_DISABLE=1; fi"
        } >> "$HOME/.bashrc"
    fi
    set -a; . "$AZURE_ENV"; set +a
    if command -v az >/dev/null 2>&1; then
        if az login --service-principal -u "$AZURE_CLIENT_ID" -p "$AZURE_CLIENT_SECRET" --tenant "$AZURE_TENANT_ID" >/dev/null 2>&1 \
           && az account set --subscription "$AZURE_SUBSCRIPTION_ID" >/dev/null 2>&1; then
            echo "Azure: logged in as the runtime service principal on subscription ${AZURE_SUBSCRIPTION_ID:0:8}..."
        else
            echo "WARN: az login as the service principal failed (login.microsoftonline.com blocked by the firewall? wrong secret?)."
        fi
    fi
else
    echo "No $AZURE_ENV; Azure tooling skipped (see projects/pgcyan/scripts/azure/bootstrap-runtime.sh)."
fi
