#!/usr/bin/env python3
import subprocess, re, sys
team = sys.argv[1] if len(sys.argv) > 1 else ""
mode = sys.argv[2] if len(sys.argv) > 2 else "any"
if not team:
    print("")
    sys.exit(0)
try:
    proc = subprocess.run(['security','find-certificate','-a','-p'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=10)
    pem = proc.stdout
except Exception:
    pem = ""
certs = re.findall(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', pem, re.DOTALL)
found = False
try:
    from cryptography import x509
    from cryptography.hazmat.backends import default_backend
    for c in certs:
        try:
            cert = x509.load_pem_x509_certificate(c.encode(), default_backend())
            ous = [a.value for a in cert.subject if a.oid.dotted_string == '2.5.4.11']
            cns = [a.value for a in cert.subject if a.oid.dotted_string == '2.5.4.3']
            if team in ous:
                if mode == "developer_id":
                    if any('Developer ID Application' in cn for cn in cns):
                        found = True
                        break
                else:
                    found = True
                    break
        except Exception:
            continue
except Exception:
    for sec in certs:
        if f'OU={team}' in sec:
            if mode == "developer_id":
                if 'Developer ID Application' not in sec:
                    continue
            found = True
            break

if not found:
    try:
        proc = subprocess.run(['security','find-identity','-v','-p','codesigning'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=10)
        out = proc.stdout
        if team in out:
            if mode == "developer_id":
                if 'Developer ID Application' in out:
                    found = True
            else:
                found = True
    except Exception:
        pass

print('yes' if found else '')
