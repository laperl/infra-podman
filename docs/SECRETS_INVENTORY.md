# Inventario de secretos

Lista de los secretos que usa la plataforma (SPEC 4.5). **Nunca valores**: solo nombres, dónde están y quién los usa.

- Copia maestra en producción: `infra-pro.kdbx`, en el portátil.
- DEV: `infra-dev.kdbx`, con las mismas rutas y valores ficticios.
- Ruta de cada entrada: `<instalación>/<nombre>`. El grupo es el nombre de la instalación (`infra_site` del repo de datos), por ejemplo `laperl/<nombre>`; no hay ningún nombre fijo en el código (R42).
- En cada grupo, un solo título por entrada: si hay dos iguales, `deploy.sh secrets` se para.
- Las bases `.kdbx` nunca entran en el repo, ni siquiera la de DEV (`.gitignore` las excluye).
- `infra-dev.kdbx` es desechable: solo existe en el portátil y se recrea con los nombres de `infra_secrets` (`inventory/dev/group_vars/all.yml` del repo de datos, SPEC 4.13). No se copia a la VM ni se le hace copia de seguridad (R17).

| Nombre del secreto en Podman | Ruta en KeePassXC | Consumidores | Rotación |
| --- | --- | --- | --- |
| `test_dummy` | `<instalación>/test_dummy` | Solo pruebas del lookup `kdbx.py` (fase 0). Solo existe en `infra-dev.kdbx` | No aplica |
| `<entorno>-pg-main-superuser-password` | `<instalación>/pg-main-superuser-password` | Superusuario de la instancia `pg-main`, el declarado en el repo de datos (`superuser:`; portátil en prod, `vmiadev` en dev). Solo se usa al crear la base, con el volumen vacío | Manual. Primero `ALTER ROLE <superusuario> PASSWORD …` dentro de la base, después `deploy.sh secrets --rotate pg-main-superuser-password --limit <máquina>` (SPEC 4.5). Cambiar solo el secreto no cambia la contraseña |
| `<entorno>-backup-restic-password` | `<instalación>/backup-restic-password` | Backup diario (`<entorno>-backup`) en las máquinas de `backup_clients`: cifra el repositorio restic local y, desde la fase 1e2, el del GX10. **Sin ella, las copias no se pueden leer** | No se rota en la fase 1. Cambiarla es `restic key add` y `restic key remove` en cada repositorio, no solo el secreto |
| `<entorno>-backup-server-password` | `<instalación>/backup-server-password` | Contraseña del usuario `<instalación>` del servidor de copias (R44). En las máquinas de `backup_clients` (la copia, `<entorno>-backup-copy`) y en las de `backup_servers` (el GX10 en prod; de ella sale el hash que guarda `<entorno>-backup-server`). **Para recuperar los datos no hace falta:** basta la clave de restic | `deploy.sh secrets --rotate backup-server-password` en el servidor y en el portátil, y `apply backup-server` en el servidor: Ansible ve que el hash ya no corresponde y lo rehace. Mientras no estén las dos, la copia falla con un aviso claro |

Al añadir un secreto: fila nueva aquí en el mismo PR que lo usa.
