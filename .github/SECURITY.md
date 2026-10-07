# Security Policy

## Supported versions

| Version | Supported |
| --- | --- |
| 0.1.x | Yes |

Security fixes land on `main` and ship in the next `0.1.x` release.

## Reporting a vulnerability

If you find a security-relevant issue (anything that could leak secrets,
allow shell injection, or escalate privileges), **please do not file a
public issue**.

Use GitHub's private **Report a vulnerability** form on the repository's
Security tab. If that form is unavailable, open a public issue that only asks
for a private contact channel, without any details of the problem.
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
as a pre-commit hook; do not bypass it. GitHub secret scanning with push
protection also blocks pushes that contain recognized secrets.

## Verifying release artifacts

Each release is published by the `release.yml` workflow when a release tag,
such as `0.1.0`, is pushed. It ships two assets: `zdx-X.Y.Z.tar.gz`, a `git archive` of the
tagged commit, and `zdx-X.Y.Z.tar.gz.sha256`, its SHA-256 checksum. The
tarball also carries a Sigstore-backed build provenance attestation.
Release tags are not protected against being moved or deleted, so rely on the
attestation, which binds the tarball to the commit and workflow that built it.

To verify a downloaded tarball:

```sh
# Download both assets of a release
gh release download X.Y.Z --repo landerox/zdx-suite

# Verify the build provenance attestation
gh attestation verify zdx-X.Y.Z.tar.gz --repo landerox/zdx-suite

# Check the SHA-256 published alongside the tarball (Linux)
sha256sum -c zdx-X.Y.Z.tar.gz.sha256

# The same check on macOS
shasum -a 256 -c zdx-X.Y.Z.tar.gz.sha256
```

For broader threat-model context, see
[`docs/security-assessment.md`](../docs/security-assessment.md).
