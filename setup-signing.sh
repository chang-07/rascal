#!/usr/bin/env bash
# setup-signing.sh — create a STABLE local code-signing identity for FinderTwo.
#
# WHY THIS EXISTS
#   macOS remembers the privacy permissions you grant an app (Full Disk Access,
#   Desktop / Documents / Downloads, removable & network volumes) by keying them
#   to the app's code-signature *identity* (its "Designated Requirement").
#
#   Ad-hoc signing (`codesign --sign -`, the old default here) produces a NEW
#   identity on every single build — so macOS thinks each rebuild is a brand-new
#   app and re-asks for every permission. That is the "it prompts on every
#   startup" problem.
#
#   This script creates ONE self-signed certificate ("FinderTwo Local Signing")
#   and stores it in your login keychain. build.sh then signs every build with
#   it, so the Designated Requirement becomes:
#
#       identifier "dev.chang.FinderTwo" and certificate leaf = H"<stable hash>"
#
#   That requirement never changes across rebuilds or reinstalls, so the
#   permissions you grant ONCE are remembered FOREVER.
#
#   The cert is NOT CA-trusted — it doesn't need to be. Trust only matters for
#   Gatekeeper distribution; for a locally-built app, an untrusted self-signed
#   identity gives a perfectly stable Designated Requirement and runs fine.
#   So this script never needs your password and never pops a dialog.
#
# USAGE
#   ./setup-signing.sh         # create the identity (idempotent — safe to re-run)
#   ./setup-signing.sh --print # just print the identity hash, if it exists
#
set -euo pipefail

CN="FinderTwo Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

cert_hash() {
    security find-certificate -c "$CN" -Z "$KEYCHAIN" 2>/dev/null \
        | awk '/SHA-1 hash:/{print $NF; exit}'
}

if [[ "${1:-}" == "--print" ]]; then
    h="$(cert_hash || true)"
    [[ -n "$h" ]] && { echo "$h"; exit 0; } || { echo "(none)"; exit 1; }
fi

existing="$(cert_hash || true)"
if [[ -n "$existing" ]]; then
    echo "✓ Signing identity '$CN' already present (hash $existing)."
    echo "  Rebuild with ./build.sh to sign with it."
    exit 0
fi

echo "→ Creating self-signed code-signing identity '$CN'…"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1) Self-signed cert + key with the codeSigning extended key usage.
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -subj "/CN=$CN" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

# 2) Bundle into PKCS#12. `-legacy` is required: modern OpenSSL 3.x defaults to
#    an encryption/MAC scheme Apple's `security import` cannot read.
openssl pkcs12 -export -legacy \
    -out "$TMP/id.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -passout pass:ftlocal >/dev/null 2>&1

# 3) Import into the login keychain. `-T /usr/bin/codesign -A` pre-authorizes
#    codesign to use the private key with no interactive prompt, ever.
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "ftlocal" -T /usr/bin/codesign -A >/dev/null 2>&1

h="$(cert_hash || true)"
if [[ -z "$h" ]]; then
    echo "✗ Import did not produce a usable identity. build.sh will fall back to ad-hoc."
    exit 1
fi

echo "✓ Created '$CN' (hash $h)."
echo "  Now run ./build.sh (or ./install.sh) — your permissions will persist across rebuilds."
