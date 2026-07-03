# Releasing Voice

## Signing certificate (already configured — don't regenerate casually)

macOS pins Microphone + Accessibility grants to the app's signing identity, so
releases are signed with one persistent self-signed cert (`Voice Self-Signed`)
instead of ad-hoc — otherwise every update would reset those permissions.

Set up via the `MACOS_CERT_P12` / `MACOS_CERT_PASSWORD` repo secrets (v0.1.14+).
Nothing to do per release.

**Only re-run `scripts/gen-signing-cert.sh` if the secret leaks.** Each run mints
a *new* cert, forcing a one-time permission reset for every existing user.

> ⚠️ The private key exists only as the write-only `MACOS_CERT_P12` secret — no
> `.p12` backup on disk. If it's lost, regenerating (and the fleet-wide reset) is
> the only path forward.

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
