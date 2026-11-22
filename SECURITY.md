# Security Policy & Health Data Compliance (HIPAA / GDPR)

A.T.H.E.N.A. processes physiological telemetry, biomechanical metrics, and longitudinal wellness indicators. Protecting athlete confidentiality, preventing unauthorized disclosure, and maintaining audit trails are fundamental architecture pillars.

---

## 1. Compliance Framework

### HIPAA (Health Insurance Portability and Accountability Act) Adherence
* **§164.312(a)(1) Access Control:** Enforces unique user identification, role-based authorization scopes (`admin`, `head_coach`, `sports_scientist`, `physician`, `coach`, `athlete`), and automatic session expiration.
* **§164.312(a)(2)(iv) Encryption at Rest:** Protected Health Information (PHI) fields (including medical referral notes and clinical narratives) utilize AES-256-GCM authenticated encryption (`tasks.encrypt_pii`).
* **§164.312(b) Audit Controls:** The `audit_middleware.py` interceptor records cryptographic hashes of requesting entities, target endpoints, timestamps, and request outcomes.

### GDPR (General Data Protection Regulation) Adherence
* **Article 9 (Special Category Data):** Biometric and health metrics require explicit consent flags recorded in `parental_consents` and user registration payloads.
* **Article 17 (Right to Erasure):** API endpoint `/api/admin/purge-athlete` enables cryptographically verified data removal and record deletion.

---

## 2. Cryptographic Architecture

* **Key Derivation:** Cryptographic keys must be provided via the `ATHENA_ENCRYPTION_KEY` environment variable (32-byte / 64-hexadecimal character entropy).
* **Token Security:** Authentication tokens use HMAC-SHA256 (JWT) with configurable expiry and stateful server-side revocation tracking via `TOKEN_BLACKLIST`.
* **Zero Real PII in Open Source Repositories:** All example data files and seed databases use synthetically generated cohorts created via randomized physiological ranges.

---

## 3. Reporting a Vulnerability

If you discover a security vulnerability or potential data leak in A.T.H.E.N.A.:

1. **Do NOT open a public GitHub issue.**
2. Email the maintainer directly at: `mishra-sportsci@users.noreply.github.com` with the subject `[SECURITY VULNERABILITY] A.T.H.E.N.A.`.
3. Include:
   * Description of the vulnerability.
   * Step-by-step reproduction instructions or proof-of-concept payload.
   * Assessment of potential exploit impact.
4. The maintainer will acknowledge receipt within 48 hours and coordinate patch verification prior to public advisory disclosure.
