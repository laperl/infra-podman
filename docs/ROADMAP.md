# Hoja de ruta

El contenido y el criterio de hecho de cada fase están en [`SPEC.md`](SPEC.md), sección 6. Aquí solo se sigue el estado y lo que queda pendiente para no olvidarlo.

## Estado de las fases

| Fase | Estado |
| --- | --- |
| 0. Base | Hecha (2026-11-02): criterio de hecho comprobado por el operador en el portátil y en DEV |
| 1. Postgres y backups | En curso. Hechos: 1a usuario de servicio (`v0.1.0`), 1b Postgres (`v0.2.0`) y 1c repo de datos (`v0.3.0`; SPEC 4.13, R38, R40). Siguen, en este orden: **1d** instancia según `POSTGRES.md` (recrear `pg-main`: superusuario como dato, locale `builtin`, UTC, checksums, rol `backup`, sin `public`, `pg_hba` generado, endurecimiento; R33–R36, R41; en PR); **1e** backups (SPEC 4.11); **1f** cierre (guía de restauración probada, avisos de imágenes nuevas, SECRETS_INVENTORY, 7.1) |
| 1b. Cortafuegos | Cuando el operador lo decida, antes de la fase 5 (R20) |
| 2. Firefly III y pgAdmin | Pendiente. Bases y usuarios como datos según `POSTGRES.md`; pgAdmin solo en `127.0.0.1` (R37) |
| 3. Observabilidad | Pendiente |
| 4. LiteLLM | Más adelante |
| 5. Agentes | Más adelante |
| 6. Análisis de logs | Más adelante |

## Pendientes que no se pueden olvidar

| Tema | Cuándo | Notas |
| --- | --- | --- |
| Protección de `main` | Si se pasa a un plan de pago | Comprobado el 2026-11-02: GitHub avisa de que los rulesets no se aplican en este repo privado sin una cuenta de organización Team. No se crean hasta entonces; el control sigue siendo el tag firmado (SPEC 5.2) |
| Token de lectura de GHCR más seguro | Cuando un servidor tenga que descargar la primera imagen propia (SPEC 5.6). En la fase 1 no hace falta, porque las imágenes son oficiales | Hoy: token clásico `read:packages` sin caducidad (R13). GHCR no admite tokens de grano fino. Opciones a evaluar: caducidad corta con rotación desde KeePassXC; una cuenta de GitHub aparte, solo de lectura y con acceso únicamente a estos paquetes, para limitar lo que expone el token; u otras que se encuentren |
| Copia de seguridad de `infra-pro.kdbx` | Resuelta a mano (2026-11-03) | El operador la guarda en un sitio cifrado y hace copias manuales periódicas. Es crítica: la clave de restic vivirá ahí (SPEC 4.11). Nunca en Git (SPEC 8) |
| Copia automática de `infra-pro.kdbx` | Fase posterior, cuando esté el disco USB del GX10 | Sincronizar el kdbx al disco USB-C del GX10 al conectarlo o cuando haga falta. Llega cifrado por KeePassXC |
| Escáner de vulnerabilidades en CI | Después de la fase 3 (R21) | Propuesta: Trivy, en el workflow `ee-image` y, más adelante, en las imágenes de los servicios |
| Propuestas automáticas de actualización | Después de la fase 3 (R21) | Propuesta: Dependabot para las actions fijadas por SHA y los paquetes de Python. Los digests de imágenes en plantillas Quadlet no los cubre; se deciden aparte. Siempre como PR |
| Validar las plantillas con Podman 6 | Cuando salga Fedora 45 | El job `quadlet-forward` del workflow `lint` ya valida con un Podman más nuevo (Fedora 44, Podman 5). Para Podman 6 basta con cambiar su imagen por el digest de `fedora:45` |
| Aprovechar Podman 5 o superior donde exista | Después de la fase 2, y solo con un servidor real con Podman 5+ en uso | Ansible lee la versión del servidor y usa `Notify=healthy` en el único sitio del patrón de espera (SPEC 4.3). El mínimo sigue siendo 4.9 (D5) |
| Límites de recursos parametrizados (memoria, CPU, procesos) | Hecho para Postgres (PR 2/4) | `postgres_memory`, `postgres_cpus`, `postgres_pids_limit` y `postgres_shm_size` en `roles/postgres/defaults/main.yml`, escritos en un único sitio de la plantilla. La fase 5 los endurece para los agentes |
| `ForwardAgent` hacia el GX10 (operador) | En cuanto funcione la confirmación de KeePassXC | Hoy `~/.ssh/config` reenvía el agente al GX10 para clonar repos. Hasta que «Require user confirmation» funcione en Sway/Wayland, cualquier proceso del GX10 puede usar tus claves mientras estás conectado. Alternativas: `ssh -A` solo cuando se vaya a clonar, o una deploy key de solo lectura por repo |
| Disco cifrado para datos propios del GX10 | Fase 4 (primer Postgres en el GX10) | Disco USB externo con LUKS y desbloqueo automático al arrancar. Opciones a estudiar: TPM (`systemd-cryptenroll`), Clevis/Tang u otra. No hace falta para los backups, que llegan cifrados |
| Espacio libre en el disco del GX10 | Antes del PR 3/4 (rest-server) | El 2026-11-03 tenía un 97 % ocupado (30 GB libres de 916 GB), en una sola partición. No hace falta reparticionar. El operador revisa qué ocupa más y borra lo que sobre. rest-server tendrá un tope de tamaño (`--max-size`) para que los backups no se coman el último espacio. Si no basta, se adelanta el disco USB |
| Backup antes de cambiar la imagen de Postgres | PR 3/4 | Antes de reiniciar Postgres con una imagen nueva, el `apply` hace un volcado, para poder volver atrás a mano (D11) |
| Avisos semanales de imágenes nuevas | PR 4/4 | `scripts/image-updates.sh` y un workflow semanal que falla, y por tanto avisa por correo, cuando un digest de `images.yml` tiene versión nueva. Aprobado el 2026-11-03 |
| Digests de los backups (fase 1e) | Al implementar 1e | Comprobados por el operador el 2026-11-03 (índice multiarquitectura, amd64 y arm64): `docker.io/restic/restic:0.19.1` → `sha256:136600b6ff6843d61d355f7f71f460a166429f35de6fd11b568fece3c9a4d510`; `docker.io/restic/rest-server:0.14.0` → `sha256:d2aff06f47eb38637dff580c3e6bce4af98f386c396a25d32eb6727ec96214a5`. Van a `playbooks/group_vars/all/images.yml` |
| Diseño de los backups acordado (fase 1e) | Al implementar 1e | En el GX10, volumen de Podman `prod-backup-repo`, nada en carpetas del operador. rest-server con `--append-only` y un tope `--max-size` (propuesta: 15 GB). Si una copia falla por espacio, el aviso explica en español qué ha pasado, cuánto se usa y qué hacer; cómo se entera el operador se propone en 1e. Cada copia lleva etiquetas de entorno, aplicación y tipo (`pgdump`, `volume`, `files`), con rutas `<app>/<tipo>/<nombre>`. Cada aplicación declara en una lista qué guarda. Se vuelcan todas las bases de cada instancia con el rol `backup`. El repo de datos también se copia |
| Gestionar varias instalaciones desde el portátil (la tuya y las de clientes) | Cuando llegue el primer cliente | Ya preparado por R42: cada instalación tiene su nombre (`infra_site`) y su grupo de KeePassXC. Falta: `deploy.conf` con una sección por instalación (`[laperl]`, `[cliente]`), cada una con su repo de datos y su `.kdbx`; `deploy.sh --site <nombre>` obligatorio; rechazo de nombres repetidos y de un repo de datos que declare otro nombre que su sección; registro de despliegues con la instalación |
| Backups de clientes en el GX10 (opcional) | En la fase 1e2 o después | Carpeta del repositorio por instalación, entorno y máquina (`laperl/prod/laptop`, `<cliente>/prod/<máquina>`). Para un cliente, un rest-server aparte (su contenedor, su volumen y su `--max-size`), para que no pueda llenar el disco ni tocar otras copias |
