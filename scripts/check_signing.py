#!/usr/bin/env python3
"""Return "yes" if the machine has a codesigning cert for DEVELOPMENT_TEAM.

Used by the Makefile (`VALID_SIGNING_IDENTITY` / `VALID_DEVELOPER_IDENTITY`).
Prints `yes` or empty; never non-zero for "not found" (Make treats output).

Team IDs live in the certificate subject OU. That value is ASN.1 inside the
PEM, not searchable as plain text — grepping PEMs or `find-identity` for the
Team ID fails even when signing is correctly set up (identity lines show the
personal unit id, not the Team ID). Decode subjects with `openssl` (always
present with Xcode CLT). `cryptography` remains an optional faster path.
"""
from __future__ import annotations

import re
import subprocess
import sys

TEAM = sys.argv[1] if len(sys.argv) > 1 else ""
MODE = sys.argv[2] if len(sys.argv) > 2 else "any"  # any | developer_id


def _run(args: list[str], **kwargs) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        timeout=kwargs.pop("timeout", 10),
        **kwargs,
    )


def _pem_certs() -> list[str]:
    try:
        pem = _run(["security", "find-certificate", "-a", "-p"]).stdout
    except Exception:
        return []
    return re.findall(
        r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----",
        pem,
        re.DOTALL,
    )


def _subject_openssl(pem: str) -> str:
    """Decode subject via openssl (OU is not plaintext in the PEM body)."""
    try:
        proc = subprocess.run(
            ["openssl", "x509", "-noout", "-subject"],
            input=pem,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
        )
        return proc.stdout if proc.returncode == 0 else ""
    except Exception:
        return ""


def _subject_cryptography(pem: str) -> str | None:
    """Optional path when cryptography is installed. None if unavailable."""
    try:
        from cryptography import x509
        from cryptography.hazmat.backends import default_backend
    except Exception:
        return None
    try:
        cert = x509.load_pem_x509_certificate(pem.encode(), default_backend())
        parts = []
        for attr in cert.subject:
            # dotted OID → short name used by openssl-style matching below
            if attr.oid.dotted_string == "2.5.4.11":
                parts.append(f"OU={attr.value}")
            elif attr.oid.dotted_string == "2.5.4.3":
                parts.append(f"CN={attr.value}")
        return ",".join(parts)
    except Exception:
        return ""


def _ou_matches(subject: str, team: str) -> bool:
    # openssl: "…, OU=TEAM, O=…" or legacy "/OU=TEAM/"
    if re.search(rf"(?:^|[,/])\s*OU\s*=\s*{re.escape(team)}(?:\s*[,/]|$)", subject):
        return True
    return False


def _cn_is_developer_id(subject: str) -> bool:
    return "Developer ID Application" in subject


def cert_matches(pem: str, team: str, mode: str) -> bool:
    subject = _subject_cryptography(pem)
    if subject is None:
        subject = _subject_openssl(pem)
    if not subject or not _ou_matches(subject, team):
        return False
    if mode == "developer_id" and not _cn_is_developer_id(subject):
        return False
    return True


def has_identity(team: str, mode: str = "any") -> bool:
    if not team:
        return False
    for pem in _pem_certs():
        if cert_matches(pem, team, mode):
            return True
    # Last resort: some setups put Team ID in identity text (rare).
    try:
        out = _run(["security", "find-identity", "-v", "-p", "codesigning"]).stdout
        if team in out:
            if mode == "developer_id":
                return "Developer ID Application" in out
            return True
    except Exception:
        pass
    return False


def main() -> None:
    print("yes" if has_identity(TEAM, MODE) else "")


if __name__ == "__main__":
    main()
