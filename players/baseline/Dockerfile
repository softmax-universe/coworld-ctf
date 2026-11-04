# The baseline policy image.
#
# The native build and runtime sit on nix-built bases defined here (caos/nim and
# caos/player-runtime) and CI publishes. YOU DO NOT NEED NIX TO BUILD THIS —
# `docker build --platform=linux/amd64 -f players/baseline/Dockerfile .` pulls
# them like any other base. Only regenerating a base needs nix, which is rare
# and happens in CI on linux/amd64, never on a contributor's machine.
#
# WHY NIX BASES, when this used to be plain debian: nim bakes ABSOLUTE
# /nix/store paths into the binary — the RUNPATH for glibc and gcc-lib, and,
# because the nim `libcurl` package dlopens curl rather than linking it, an
# absolute path for libcurl.so.4. A binary built on one of these bases
# therefore only runs on a runtime image built from THE SAME nixpkgs pin, which
# caos/nim and caos/player-runtime share. In exchange:
#
#   - `caos-cli run-tool build-player` produces a binary that is linked exactly
#     like the one this file builds, so it CAN be dropped into the runtime
#     stage as-is. Nothing here does that — this file is the standalone path,
#     and it compiles from source. Assembling the image around a caos-built
#     binary is the `build-image` tool's job.
#   - the image is 69 MB rather than 93 MB, and all of it is used — the old
#     debian base was 78 MB to carry a 1 MB policy.
#   - the runtime stage has no compiler, no apt and no shell.
#
# A pin mismatch dies LOUDLY at startup ("could not load: libcurl.so(|.4)"),
# before the websocket, because nim's dynlib load runs at module init. It
# cannot degrade into a policy that runs while silently dropping telemetry.
#
# The two ARGs below let a local build point at locally-built bases:
#   docker build --build-arg NIM_IMAGE=ctf-nim:latest \
#                --build-arg RUNTIME_IMAGE=coworld-ctf-runtime:latest ...
# The tag IS the nixpkgs pin both bases were built from. Bumping it is a
# deliberate two-line edit, and the two lines must move together — that is the
# whole coupling, made visible instead of implicit.
ARG NIM_IMAGE=ghcr.io/softmax-universe/coworld-ctf-nim:b47ad65d
ARG RUNTIME_IMAGE=ghcr.io/softmax-universe/coworld-ctf-runtime:b47ad65d

# ── Season 2 playbook: every reference play under play_sdk/reference/ ─────
# Reused verbatim from policies/starters/common/build_playbook.sh (the same
# recipe the starter policies bake their playbook with) so the baseline's
# Season 2 half calls the SAME compiled plays a starter would, never its own
# fork of them. Pinned to linux/amd64 like the starters' own Dockerfiles:
# the official Nim image publishes no arm64 manifest, and wasm is
# architecture-neutral either way.
FROM --platform=linux/amd64 nimlang/nim:2.2.6 AS playbook
ARG WASI_SDK_VERSION=33
ARG WASI_SDK_RELEASE=33.0
RUN set -eux; \
    case "$(uname -m)" in \
      x86_64)  wasi_target=x86_64-linux ;; \
      aarch64) wasi_target=arm64-linux ;; \
      *) echo "unsupported arch $(uname -m)" >&2; exit 1 ;; \
    esac; \
    archive="wasi-sdk-${WASI_SDK_RELEASE}-${wasi_target}.tar.gz"; \
    curl -fsSL -o /tmp/wasi-sdk.tar.gz \
      "https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-${WASI_SDK_VERSION}/${archive}"; \
    mkdir -p /opt/wasi-sdk; \
    tar -xzf /tmp/wasi-sdk.tar.gz --strip-components=1 -C /opt/wasi-sdk; \
    rm /tmp/wasi-sdk.tar.gz
ENV WASI_SDK_PATH=/opt/wasi-sdk
WORKDIR /src
COPY play_sdk ./play_sdk
COPY tools/runtime_spike ./tools/runtime_spike
COPY policies/starters/common/build_playbook.sh ./policies/starters/common/
RUN chmod +x policies/starters/common/build_playbook.sh \
    && policies/starters/common/build_playbook.sh /playbook

FROM ${NIM_IMAGE} AS build
# nimby writes its global package tree under $HOME; the image has no home dir.
ENV HOME=/tmp
WORKDIR /workspace/ctf
COPY nimby.lock .
RUN nimby --global sync nimby.lock
COPY . .
ARG NIM_DEFINES=""
# buildDefines feeds artlog meta.json: the full define set this build was
# TOLD to compile with (records intent, not that guarded code exists).
#
# A FROM-SCRATCH COMPILE, deliberately, and NOT routed through the image's
# /ccache-bin/gcc shadow. A build stage's filesystem is discarded, so ccache
# here would be a cold local cache on every build: a fork per compile buying
# nothing, while reading as though the build were cached. The caos redis cache
# is not reachable from `docker build` either. An unobservable cache is one you
# cannot trust (see caos-tools/lib/common.sh, setup_ccache) — so rather than
# ship a cache nobody can see, this path is honestly slow, and the fast path is
# `run-tool build-player`, which reports its hit rate on every run.
RUN nim c \
  -d:release $NIM_DEFINES \
  -d:useMalloc \
  -d:buildDefines="-d:release $NIM_DEFINES -d:useMalloc" \
  --opt:speed \
  --stackTrace:on \
  --nimcache:/tmp/ctf-nimcache \
  --out:baseline \
  players/baseline/baseline.nim

FROM ${RUNTIME_IMAGE}
COPY --from=build /workspace/ctf/baseline /bin/baseline
# The Season 2 playbook: s2play.nim reads BASELINE_PLAYBOOK (defaults to
# /playbook) at startup and uploads whichever of its known reference plays
# are present. Missing this stage is not fatal at runtime -- a play seat
# with nothing uploaded simply plays the engine's own default play -- but a
# real match wants the reference plays actually driving, so this image
# always ships them.
COPY --from=playbook /playbook /playbook
ENV BASELINE_PLAYBOOK=/playbook
CMD ["/bin/baseline"]
