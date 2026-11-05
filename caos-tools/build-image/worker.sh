#!/usr/bin/env bash
# Assemble the submittable policy image. See .caos-expr for the agent-facing
# docs; this header is the mechanism.
#
# TWO STAGES, one script, selected by a curried --stage:
#
#   narrow  (default) narrow the tree, curry `build-player`, run-then it
#   assemble the `then`: --result is build-player's {bin,report,status}
#
# WHY THIS COMPILES NOTHING. players/baseline/Dockerfile's build stage and
# caos/nim are the same image on the same nixpkgs pin, so `build-player`'s
# binary is linked exactly like the shipped one — same glibc RUNPATH, same
# absolute dlopen path for libcurl. That is the whole point of the pin
# coupling: the image is one ~1 MB layer on the published runtime base, not a
# second compile of the same source.
#
# WHY A GIT-DOCKER DELTA AND NOT A TARBALL. caos converts {base, config.json,
# layerNN/…} into an image digest server-side (design/flake-images.md; it is
# how std/flake-builder stacks the caos additions onto a flake image). So the
# 68 MB runtime base is NAMED, never copied: it does not enter the CAS, no job
# fetches it, and a policy rebuild moves only its own layer. A docker-archive
# would have put the whole image in the CAS to say one megabyte had changed.
set -euo pipefail

fail() { echo "BUILD-IMAGE FAIL: $*" >&2; exit 1; }

# The runtime base the Dockerfile names. Kept in step with it BY HAND, which is
# the coupling this repo chose to make visible rather than clever: the tag is
# the nixpkgs pin, and a mismatch dies loudly at startup rather than silently.
DEFAULT_RUNTIME=ghcr.io/softmax-universe/coworld-ctf-runtime:b47ad65d

stage=narrow
if caos get /cas/args/stage 2>/dev/null; then stage=$(cat /cas/args/stage); fi

case "$stage" in

narrow)
  caos get /cas/args/in
  caos get /cas/args/in/caos-tools
  # -r: we CURRY these bytes into the player job, so we need the file, not a
  # placeholder. From the workspace tree rather than curried in the expression:
  # a tool's `.caos-expr` is evaluated against its OWN directory, so `..` does
  # not reach a sibling tool. (The existing tools reach caos-tools/lib the same
  # way.)
  caos get -r /cas/args/in/caos-tools/build-player

  # Hand the whole tree to build-player and let ITS narrow stage decide what a
  # policy build reads. Duplicating that list here is how the two would drift.
  fwd=("--worker1:@=/cas/args/in/caos-tools/build-player/worker.sh")
  if [ -e /cas/args/player ]; then fwd+=("--player:@=/cas/args/player"); fi
  if [ -e /cas/args/defines ]; then fwd+=("--defines:@=/cas/args/defines"); fi
  # build-player runs on the NIM image, not ours: it compiles.
  player=$(caos curry --base:@=/cas/args/nim "${fwd[@]}") \
    || fail "currying build-player"

  next=("--worker1:@=/cas/args/worker1" --stage=assemble)
  if [ -e /cas/args/player ]; then next+=("--player:@=/cas/args/player"); fi
  if [ -e /cas/args/runtime ]; then next+=("--runtime:@=/cas/args/runtime"); fi
  then_=$(caos curry --base:@=/cas/args/base "${next[@]}") \
    || fail "currying assemble"

  caos run-then /cas/args/in --run:hash="$player" --then:hash="$then_"
  ;;

assemble)
  # --result is build-player's tree: { bin, report, status }.
  caos get -r /cas/args/result

  status=$(cat /cas/args/result/status 2>/dev/null || echo 1)
  R=/tmp/result; rm -rf "$R"; mkdir -p "$R"
  if [ "$status" != "0" ]; then
    # The compile is the whole job when it fails. Return ITS diagnostics rather
    # than a confusing "no binary" from the assembly step — an agent calling
    # this tool wants the nim errors, not our bookkeeping.
    { cat /cas/args/result/report 2>/dev/null
      echo; echo "FAILED: the policy did not compile, so there is no image."
    } > "$R/report"
    caos put "$R" /cas/out
    exit 0
  fi

  player=baseline
  if [ -e /cas/args/player ]; then caos get /cas/args/player; player=$(cat /cas/args/player); fi
  runtime=$DEFAULT_RUNTIME
  if [ -e /cas/args/runtime ]; then caos get /cas/args/runtime; runtime=$(cat /cas/args/runtime); fi

  # The base's CONFIG. It is not ours to invent: it carries SSL_CERT_FILE (a
  # store path unknowable without nix) and the rootfs diff_ids that every later
  # layer stacks onto, so the delta must inherit it rather than construct one.
  #
  # skopeo rather than curl: it already speaks the token dance, the auth file
  # and both manifest media types, and it is in this image precisely so we do
  # not reimplement a registry client badly.
  #
  # TLS is verified for a real registry and skipped for a bare host:port, which
  # is docker's own rule for telling a registry name from a path segment: a
  # host with no dot is local (the caos stack's own registry answers plain HTTP
  # on caos-registry:5000). Nothing secret moves here — the base is public and
  # this is a pull.
  tlsflag=--tls-verify=true
  case "${runtime%%/*}" in *.*) ;; *) tlsflag=--tls-verify=false ;; esac
  skopeo inspect --config $tlsflag "docker://$runtime" > /tmp/base-config.json \
    || fail "cannot read the config of $runtime (is the base published?)"

  # PIN THE BASE BY DIGEST. caos refuses a mutable tag in a git-docker delta
  # ("is mutable; use <name>@sha256:..."), and it is right to: the delta is
  # content-addressed, so a base that could be re-tagged underneath it would
  # make one hash mean two different images. Resolving here also means the
  # recorded base is the exact bytes this build read the config from, not
  # whatever the tag points at when someone later converts the tree.
  basedig=$(skopeo inspect $tlsflag --format '{{.Digest}}' "docker://$runtime") \
    || fail "cannot resolve $runtime to a digest"
  basepin="${runtime%%:*}@$basedig"
  case "$runtime" in *:*/*|*/*:*) basepin="${runtime%:*}@$basedig" ;; esac

  img=$R/image; rm -rf "$img"; mkdir -p "$img/layer00/bin"
  cp /cas/args/result/bin "$img/layer00/bin/$player"
  # Git trees cannot encode an exec bit the way an image layer needs, so caos
  # takes it from a sidecar (the same mechanism std/flake-builder uses for the
  # setuid /bin/caos).
  printf '{"mode":"0755","uid":0,"gid":0}' > "$img/layer00/bin/$player.caosmeta"

  printf 'docker://%s' "$basepin" > "$img/base"
  # Cmd names THIS policy. Everything else — Env, and SSL_CERT_FILE in
  # particular — is the base's and is carried through untouched.
  jq --arg cmd "/bin/$player" '.config.Cmd = [$cmd]' /tmp/base-config.json \
    > "$img/config.json" || fail "rewriting the image config"

  { echo "policy:  players/$player/$player.nim"
    echo "base:    $basepin"
    echo "         (referenced by digest, not copied — resolved from $runtime)"
    echo "layer:   /bin/$player  ($(stat -c %s /cas/args/result/bin) bytes)"
    echo "config:  the base's, with Cmd rewritten to /bin/$player"
    echo
    echo "image/ is a git-docker delta the server converts to a digest. The"
    echo "68 MB base never enters the CAS; a policy rebuild moves only the"
    echo "layer above. Hand image/ to upload-image."
    echo
    echo "BUILD-IMAGE OK"
  } > "$R/report"
  caos put "$R" /cas/out
  ;;

*) fail "unknown stage: $stage" ;;
esac
