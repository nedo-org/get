#!/usr/bin/env bash
set -euo pipefail

# THE BOOTSTRAP. This is the ONE file a person is asked to trust and run:
#
#   curl -fsSL https://raw.githubusercontent.com/nedo-org/get/main/install.sh | bash -s -- 1.2.3
#
# It fetches a versioned payload, proves it is the one that was published, unpacks it,
# puts a pinned helm next to it, and hands over to the installer inside. Everything it
# touches lives under ~/.nedo; nothing is written into the directory it runs from.
#
# IT LIVES IN TWO PLACES ON PURPOSE, and this is the source of truth. The copy that
# people curl is in the PUBLIC repo nedo-org/get, because the release assets have to be
# reachable by somebody who cannot read nedo-org/nedo - which is the whole point.
# scripts/docs/releasing.md says how the two are kept in step.
#
# WHY IT IS NOT THE INSTALLER ITSELF. Everything here is about GETTING the payload;
# nothing here knows what nedo is. That split is what lets the installer change freely
# between releases while this file, the one that is curl'd from the internet and run
# unread, stays small enough to audit in one sitting.

NEDO_GET_REPO="${NEDO_GET_REPO:-nedo-org/get}"
NEDO_HOME="${NEDO_HOME:-$HOME/.nedo}"

die() { echo "[nedo] $*" >&2; exit 1; }
say() { echo "[nedo] $*" >&2; }

# --- what we need before we can do anything ----------------------------------
# curl and tar only. kubectl/jq/ssh/openssl are the INSTALLER's prerequisites and are
# checked by its own preflight, which produces a far better message than anything this
# file could - and checking them here would mean two lists to keep in step.
for tool in curl tar; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required and was not found."
done

# sha256, spelled differently on the two platforms this runs on.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else die "neither sha256sum nor shasum is available: the payload cannot be verified, and an unverified payload is not something to run."
  fi
}

# --- which version -----------------------------------------------------------
# THE `v` IS ACCEPTED AND IMMEDIATELY DROPPED. The git tag carries it, no artifact does;
# taking both spellings here means nobody has to know which is which.
VERSION="${1:-latest}"
# SHIFTED OFF, because everything after it belongs to the installer. Without this the
# version reaches `install.sh` as a positional argument and `nedo_refuse_rest` kills the
# run with "unknown argument: 1.2.3" - at the handover, after every download succeeded.
[[ $# -gt 0 ]] && shift
if [[ "$VERSION" == "latest" ]]; then
  say "resolving the latest release of ${NEDO_GET_REPO}..."
  # No jq: this runs before the installer's prerequisites are checked, and a bootstrap
  # that needs a JSON parser to find out its own version is a bootstrap with one more
  # thing that can be missing.
  VERSION="$(curl -fsSL "https://api.github.com/repos/${NEDO_GET_REPO}/releases/latest" \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
  [[ -n "$VERSION" ]] || die "could not resolve the latest release of ${NEDO_GET_REPO}. Name a version explicitly."
fi
VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] \
  || die "'${VERSION}' is not a version this can fetch (expected 1.2.3, or v1.2.3)."

PAYLOAD="nedo-installer-${VERSION}"
BASE="https://github.com/${NEDO_GET_REPO}/releases/download/v${VERSION}"
DEST="${NEDO_HOME}/versions/${VERSION}"

# --- the payload -------------------------------------------------------------
# 0700 THROUGHOUT, because the config directory below it holds the platform's secrets
# and because a payload somebody else can write is a payload somebody else chose.
mkdir -p "${NEDO_HOME}/versions"
chmod 700 "$NEDO_HOME"

if [[ -d "$DEST" && -f "$DEST/VERSION" ]]; then
  say "version ${VERSION} is already unpacked at ${DEST}"
else
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  say "downloading ${PAYLOAD}.tar.gz..."
  curl -fsSL -o "$TMP/${PAYLOAD}.tar.gz" "${BASE}/${PAYLOAD}.tar.gz" \
    || die "could not download ${BASE}/${PAYLOAD}.tar.gz - is v${VERSION} a published release?"
  curl -fsSL -o "$TMP/SHA256SUMS" "${BASE}/SHA256SUMS" \
    || die "could not download ${BASE}/SHA256SUMS. Refusing to unpack a payload with nothing to check it against."

  # VERIFIED BY LOOKING UP OUR OWN LINE, not by running the checksum file. `sha256sum -c`
  # would happily report success on a file that lists something else entirely, and it
  # needs the working directory to match. This compares one hash to one hash.
  want="$(grep " ${PAYLOAD}.tar.gz\$" "$TMP/SHA256SUMS" | cut -d' ' -f1 | head -1)"
  [[ -n "$want" ]] || die "SHA256SUMS does not mention ${PAYLOAD}.tar.gz."
  got="$(sha256_of "$TMP/${PAYLOAD}.tar.gz")"
  [[ "$want" == "$got" ]] || die "checksum mismatch for ${PAYLOAD}.tar.gz (expected ${want}, got ${got}). Nothing has been unpacked."
  say "checksum ok"

  rm -rf "${DEST}.partial"
  mkdir -p "${DEST}.partial"
  tar -xzf "$TMP/${PAYLOAD}.tar.gz" -C "${DEST}.partial" --strip-components=1
  # RENAMED INTO PLACE ONLY ONCE COMPLETE, so an interrupted download can never leave a
  # half-unpacked version directory that the check above would then accept as done.
  rm -rf "$DEST"
  mv "${DEST}.partial" "$DEST"
  # REMOVED HERE, not left to the EXIT trap: this script ends in `exec`, which replaces
  # the process - so the trap never fires and the tarball stays in /tmp for ever.
  rm -rf "$TMP"
  trap - EXIT
  say "unpacked to ${DEST}"
fi

# --- helm, pinned, next to the payload ---------------------------------------
# THE ONE PREREQUISITE THIS FILE REMOVES, and the reason it is worth removing: the
# platform's releases are managed with one helm MAJOR, and a mismatch is SILENT - helm
# reads the other major's release Secrets quite happily, so the difference surfaces
# later, as an upgrade behaving differently. Asking every operator to arrange that by
# hand is asking them to get a silent thing right.
#
# THE VERSION IS READ OUT OF THE PAYLOAD, never written here: scripts/cluster/lib.sh is
# the one copy of every pinned version in this platform, and a second copy in the file
# that downloads the binary is exactly how the two drift.
HELM_PINNED="$(sed -n 's/^export NEDO_HELM_VERSION="\${NEDO_HELM_VERSION:-\([^}]*\)}"/\1/p' \
  "$DEST/scripts/cluster/lib.sh" | head -1)"
HELM_BIN="$DEST/bin/helm"
if [[ -z "$HELM_PINNED" ]]; then
  say "this payload names no pinned helm; leaving HELM_BIN to the installer's own default."
  HELM_BIN=""
elif [[ -x "$HELM_BIN" ]]; then
  say "helm ${HELM_PINNED} already in place"
else
  case "$(uname -s)" in
    Darwin) helm_os=darwin ;;
    Linux)  helm_os=linux ;;
    *) die "unsupported platform $(uname -s) - install helm ${HELM_PINNED} yourself and set HELM_BIN." ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) helm_arch=arm64 ;;
    x86_64|amd64)  helm_arch=amd64 ;;
    *) die "unsupported architecture $(uname -m) - install helm ${HELM_PINNED} yourself and set HELM_BIN." ;;
  esac
  helm_tgz="helm-v${HELM_PINNED}-${helm_os}-${helm_arch}.tar.gz"
  TMPH="$(mktemp -d)"
  say "fetching helm ${HELM_PINNED} (${helm_os}/${helm_arch})..."
  curl -fsSL -o "$TMPH/$helm_tgz" "https://get.helm.sh/${helm_tgz}" || die "could not download ${helm_tgz}."
  # helm publishes a checksum next to every archive; a pinned binary nobody checked is
  # a pin in name only.
  want_helm="$(curl -fsSL "https://get.helm.sh/${helm_tgz}.sha256sum" | cut -d' ' -f1 | head -1)"
  got_helm="$(sha256_of "$TMPH/$helm_tgz")"
  [[ -n "$want_helm" && "$want_helm" == "$got_helm" ]] \
    || die "checksum mismatch for ${helm_tgz}. Nothing has been installed."
  mkdir -p "$DEST/bin"
  tar -xzf "$TMPH/$helm_tgz" -C "$TMPH"
  mv "$TMPH/${helm_os}-${helm_arch}/helm" "$HELM_BIN"
  chmod 755 "$HELM_BIN"
  rm -rf "$TMPH"
  say "helm ${HELM_PINNED} placed at ${HELM_BIN}"
fi

# --- the config, which does NOT live in a version directory -------------------
# A version directory is disposable - an upgrade makes a new one - and the config is the
# platform's identity and its secrets. Keeping the two apart is what makes an upgrade a
# download rather than a migration.
export NEDO_CONFIG_DIR="${NEDO_CONFIG_DIR:-$NEDO_HOME}"
mkdir -p "$NEDO_CONFIG_DIR"
chmod 700 "$NEDO_CONFIG_DIR"

# THE FLAG IS READ HERE TOO, and only to name the right file below. install.sh owns the
# real parsing (scripts/lib-instance.sh); this is a message, not a decision - but a
# message that says "there is no configuration at ~/.nedo/.env" while the operator asked
# for --instance prod is worse than no message.
INSTANCE="${NEDO_INSTANCE:-default}"
_prev=""
for _arg in "$@"; do
  case "$_arg" in
    --instance=*) INSTANCE="${_arg#*=}" ;;
    *) [[ "$_prev" == "--instance" ]] && INSTANCE="$_arg" ;;
  esac
  _prev="$_arg"
done
if [[ "$INSTANCE" == "default" ]]; then
  CONFIG="$NEDO_CONFIG_DIR/.env"
else
  CONFIG="$NEDO_CONFIG_DIR/instances/${INSTANCE}.env"
fi
if [[ ! -f "$CONFIG" ]]; then
  cp "$DEST/.env.example" "${CONFIG}.example"
  say ""
  say "There is no configuration at ${CONFIG}."
  say "A reference copy has been written to ${CONFIG}.example - fill it in and rename it:"
  say ""
  say "    \$EDITOR ${CONFIG}.example && mv ${CONFIG}.example ${CONFIG}"
  say "    ${DEST}/scripts/install.sh${NEDO_INSTANCE:+ --instance $NEDO_INSTANCE}"
  say ""
  say "Nothing has been installed."
  exit 1
fi

# --- hand over ----------------------------------------------------------------
# exec, so what follows is the installer's own process: its exit status is this
# command's, and nothing here wraps or reinterprets its output.
say "handing over to the installer (version ${VERSION})"
# An `if`, not `[[ ... ]] && export`: under `set -e` that compound returns 1 when HELM_BIN
# is empty, which ENDS THE SCRIPT one line before the handover - on the path where this
# file has already done all of its work.
if [[ -n "$HELM_BIN" ]]; then export HELM_BIN; fi
exec "$DEST/scripts/install.sh" "$@"
