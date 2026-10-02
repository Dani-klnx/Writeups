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
