# Security Policy

## Supported versions

`zdx` is a personal collection of Zsh tooling; only the `main`
branch is actively maintained. Older tags are kept for reference but do
not receive security fixes.

## Reporting a vulnerability

If you find a security-relevant issue (anything that could leak secrets,
allow shell injection, or escalate privileges), **please do not file a
public issue**.

Use GitHub's private **Report a vulnerability** form on the repository's
Security tab. If that form is unavailable, email **landerox@gmail.com**.
Include:

- A clear description of the issue
- Steps to reproduce or a minimal proof-of-concept
- Any suggested mitigation

You can expect:

- Acknowledgement within 7 days
- A public fix released as soon as feasible (typical: 14–30 days)
- Credit in the release notes if you'd like (opt-in)

## Scope reminders

This repo loads `.zsh` files into your interactive shell. Treat every
contribution that touches `eval`, `source <variable>`, command
substitution on untrusted input, credential files, or temp file handling
as security-sensitive.

Secret scanning is enforced by [`gitleaks`](https://github.com/gitleaks/gitleaks)
as a pre-commit hook; do not bypass it.

## Verifying release artifacts

Every release ships a source tarball plus its SHA-256 checksum, and the
tarball is attested via Sigstore-backed build provenance through the
`release.yml` workflow. To verify a downloaded tarball:

```sh
# Cryptographic attestation against GitHub's transparency log
gh attestation verify zdx-X.Y.Z.tar.gz --repo landerox/zdx-suite

# Or check the SHA-256 published alongside the tarball
sha256sum -c zdx-X.Y.Z.tar.gz.sha256
```

For broader threat-model context, see
[`docs/security-assessment.md`](../docs/security-assessment.md).
