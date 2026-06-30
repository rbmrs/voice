#!/bin/zsh
# Generate the STABLE self-signed code-signing certificate that keeps macOS
# permissions (Microphone + Accessibility) across app updates.
#
# Why this exists: TCC keys every permission grant to the app's code-signing
# "designated requirement". An ad-hoc signed app (codesign --sign -) has no
# stable identity — its requirement is just the cdhash, which changes on every
# build — so each Sparkle/cask update looks like a brand-new app and the user
# loses Microphone + Accessibility. Signing with ONE persistent certificate
# pins the requirement to that cert, so grants survive updates.
#
# Run this ONCE. It prints the two GitHub Actions secrets the release workflow
# needs (MACOS_CERT_P12, MACOS_CERT_PASSWORD) and imports the identity into your
# login keychain so you can sign locally too (IDENTITY="Voice Self-Signed").
#
# Re-running generates a DIFFERENT cert — which would itself reset everyone's
# permissions once. Only do that if the secret leaks. Keep the p12 backed up.

set -euo pipefail

CN=${CN:-"Voice Self-Signed"}      # must match IDENTITY in scripts/sign.sh / release.yml
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

key="$out/key.pem"
cert="$out/cert.pem"
p12="$out/cert.p12"
pass=$(openssl rand -base64 24)

echo "==> generating self-signed code-signing cert: CN=$CN"
# digitalSignature + codeSigning EKU is what codesign requires of an identity.
# 100-year validity so it never silently expires mid-project.
openssl req -x509 -newkey rsa:2048 -nodes -days 36500 \
  -keyout "$key" -out "$cert" \
  -subj "/CN=$CN" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

openssl pkcs12 -export -inkey "$key" -in "$cert" -out "$p12" \
  -name "$CN" -passout "pass:$pass"

# Import into the login keychain so local `zsh scripts/sign.sh` (IDENTITY="$CN")
# works, and self-check that codesign actually accepts the identity.
# Drop any existing cert with this CN first — duplicates make codesign report
# the identity as "ambiguous" and fail.
echo "==> importing into login keychain and verifying it can sign"
while h=$(security find-certificate -c "$CN" -Z login.keychain-db 2>/dev/null | awk '/SHA-1/{print $3; exit}'); [[ -n "$h" ]]; do
  security delete-certificate -Z "$h" login.keychain-db >/dev/null 2>&1 || break
done
security import "$p12" -P "$pass" -T /usr/bin/codesign >/dev/null
probe="$out/probe"; cp /usr/bin/true "$probe"
codesign --force --sign "$CN" "$probe"
codesign --verify --strict "$probe"
echo "    ✓ codesign accepts identity \"$CN\""

b64=$(base64 < "$p12" | tr -d '\n')

cat <<EOF

================================================================================
 Add these two repository secrets (Settings → Secrets and variables → Actions):

   MACOS_CERT_PASSWORD = $pass

   MACOS_CERT_P12 (base64, one line):
--------------------------------------------------------------------------------
$b64
--------------------------------------------------------------------------------

 Quick path with the gh CLI:
   printf '%s' '$b64' | gh secret set MACOS_CERT_P12
   printf '%s' '$pass' | gh secret set MACOS_CERT_PASSWORD

 Once set, the release workflow signs with this stable identity and updates no
 longer reset permissions. Back up the values above somewhere safe — they are
 not recoverable from the keychain.
================================================================================
EOF
