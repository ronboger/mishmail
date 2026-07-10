# Security Policy

MishMail is a local-first mail client that handles OAuth tokens and renders
untrusted email. Security reports are taken seriously.

## Reporting a vulnerability

Please **do not** open a public issue for security problems. Instead, use
GitHub's **private vulnerability reporting** (Security → Report a vulnerability)
or email the maintainer directly. Include:

- what the issue is and where in the code,
- a proof-of-concept or reproduction if you have one,
- the impact you think it has.

You'll get an acknowledgement as soon as possible.

## Scope

Especially interesting:

- HTML-email rendering escapes (navigation, remote content, local-file access),
- OAuth/PKCE or loopback-listener weaknesses,
- Keychain/token exposure,
- SQL injection or path traversal,
- attachment handling.

## Design notes

The threat model and mitigations are summarized in the
[Security section of the README](README.md#security).
