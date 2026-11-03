# Hoja de ruta

El contenido y el criterio de hecho de cada fase están en [`SPEC.md`](SPEC.md), sección 6. Aquí solo se sigue el estado y lo que queda pendiente para no olvidarlo.

## Estado de las fases

| Fase | Estado |
| --- | --- |
| 0. Base | Hecha (2026-11-02): criterio de hecho comprobado por el operador en el portátil y en DEV |
| 1. Postgres y backups | En curso: PR 1/4 (usuario de servicio y portátil como servidor). Después: 2/4 Postgres y `quadlet_deploy`, 3/4 backups, 4/4 cierre |
| 1b. Cortafuegos | Cuando el operador lo decida, antes de la fase 5 (R20) |
| 2. Firefly III | Pendiente |
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
| Límites de recursos parametrizados (memoria, CPU, procesos) | Fase 1, empezando por Postgres | Parámetros por servicio con valor por defecto, escritos en un único sitio de las plantillas. En 4.9: `PodmanArgs=--memory= --cpus=` y `PidsLimit=` (ver [`COMPATIBILITY.md`](COMPATIBILITY.md)). La fase 5 los endurece para los agentes. Nombres y valores por defecto se proponen en el PR de la fase 1 |
| Cargar los valores por defecto de los roles al validar plantillas | Fase 1 | `scripts/render-quadlets.yml` hoy solo usa `tests/quadlet/ci_vars.yml`; con roles reales tendrá que leer también sus `defaults/` |
| `ForwardAgent` hacia el GX10 (operador) | En cuanto funcione la confirmación de KeePassXC | Hoy `~/.ssh/config` reenvía el agente al GX10 para clonar repos. Hasta que «Require user confirmation» funcione en Sway/Wayland, cualquier proceso del GX10 puede usar tus claves mientras estás conectado. Alternativas: `ssh -A` solo cuando se vaya a clonar, o una deploy key de solo lectura por repo |
| Disco cifrado para datos propios del GX10 | Fase 4 (primer Postgres en el GX10) | Disco USB externo con LUKS y desbloqueo automático al arrancar. Opciones a estudiar: TPM (`systemd-cryptenroll`), Clevis/Tang u otra. No hace falta para los backups, que llegan cifrados |
| Espacio libre en el disco del GX10 | Antes del PR 3/4 (rest-server) | El 2026-11-03 tenía un 97 % ocupado (30 GB libres de 916 GB), en una sola partición. No hace falta reparticionar. El operador revisa qué ocupa más y borra lo que sobre. rest-server tendrá un tope de tamaño (`--max-size`) para que los backups no se coman el último espacio. Si no basta, se adelanta el disco USB |
