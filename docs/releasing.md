# Releasing Voice

## Signing certificate (already configured — do NOT regenerate casually)

macOS attributes Microphone + Accessibility grants to the app's code-signing
identity. Ad-hoc signing has no stable identity, so every update would reset
those permissions. Releases are therefore signed with one persistent
self-signed cert, `Voice Self-Signed`.

**This is already set up.** The `MACOS_CERT_P12` / `MACOS_CERT_PASSWORD` repo
secrets were configured 2026-06-29; v0.1.14 onward are signed with this identity.
Nothing to do per release.

`scripts/gen-signing-cert.sh` is the bootstrap/recovery tool that minted that
cert. **Only re-run it if the secret leaks** — every run mints a *new, different*
cert, which forces a one-time permission reset for every existing user (the new
cert no longer matches the requirement their grants are pinned to). It is not
idempotent across the fleet.

> ⚠️ Backup status: the live cert's private key now exists **only** as the
> `MACOS_CERT_P12` GitHub secret, which is write-only (cannot be read back). No
> `.p12` backup remains on disk. If that secret is ever lost, the only path
> forward is regenerating (and eating the one-time fleet permission reset).

## Tagging a release

Create an annotated tag whose message is the one-line summary you want shown at the top of the GitHub Release:

```bash
git tag -a v0.1.5 -m "Fix popup centering after send"
git push origin v0.1.5
```

The release workflow uses that tag message as the `What Changed` line in the published GitHub Release notes, then appends the install instructions, SHA256, and full changelog link.

## Editing an existing release

Existing GitHub Releases can be edited later in the GitHub UI or with `gh`:

```bash
gh release edit v0.1.5 --notes-file /path/to/release-notes.md
```

Keep the summary brief and user-facing. One sentence is enough.
