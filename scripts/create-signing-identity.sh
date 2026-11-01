#!/usr/bin/env bash
# Creates a self-signed code-signing certificate in the login keychain, once.
#
# An ad-hoc signature changes with every build, so macOS treats each build as a new app and asks
# for the Keychain approval and the Accessibility and Automation grants again. A certificate
# keeps the signing identity stable across builds. It is not a Developer ID: Gatekeeper still
# warns on other Macs (see "Installation" in the README), and the app cannot be notarised.
#
#   ./scripts/create-signing-identity.sh ["Certificate name"]
#
# Marking the certificate as trusted for code signing makes macOS ask for your login password.
# The first build that signs with it may ask once to let `codesign` use the key: choose
# "Always Allow".
set -euo pipefail

name="${1:-Clipkeep Local Signing}"
keychain="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -qF "\"$name\""; then
  echo "A valid code-signing identity \"$name\" already exists."
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
passphrase="$(/usr/bin/openssl rand -hex 16)"

cat > "$work/certificate.cnf" <<CONFIG
[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no
[subject]
CN = $name
[extensions]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONFIG

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/certificate.cnf" \
  -keyout "$work/key.pem" -out "$work/certificate.pem" 2> /dev/null
/usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/certificate.pem" \
  -out "$work/identity.p12" -passout "pass:$passphrase"

security import "$work/identity.p12" -k "$keychain" -P "$passphrase" -T /usr/bin/codesign
security add-trusted-cert -p codeSign -k "$keychain" "$work/certificate.pem"

if security find-identity -v -p codesigning | grep -qF "\"$name\""; then
  echo "Created the code-signing identity \"$name\"."
else
  echo "The certificate was imported but is not valid for code signing yet." >&2
  exit 1
fi
