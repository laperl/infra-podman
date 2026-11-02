# Hoja de ruta

El contenido y el criterio de hecho de cada fase están en [`SPEC.md`](SPEC.md), sección 6. Aquí solo se sigue el estado y lo que queda pendiente para no olvidarlo.

## Estado de las fases

| Fase | Estado |
| --- | --- |
| 0. Base | En curso: 0a (estructura, docs, `lint`) · 0b (imagen de Ansible, lookup `kdbx.py`) · 0c (`deploy.sh`, firma SSH) |
| 1. Postgres | Pendiente |
| 2. Firefly III | Pendiente |
| 3. Observabilidad | Pendiente |
| 4. LiteLLM | Más adelante |
| 5. Agentes | Más adelante |
| 6. Análisis de logs | Más adelante |

## Pendientes que no se pueden olvidar

| Tema | Cuándo | Notas |
| --- | --- | --- |
| Protección de `main` | Si se pasa a un plan de pago | Comprobado el 2026-11-02: GitHub avisa de que los rulesets no se aplican en este repo privado sin una cuenta de organización Team. No se crean hasta entonces; el control sigue siendo el tag firmado (SPEC 5.2) |
| Escáner de vulnerabilidades en CI | Al cerrar la fase 0, antes de la fase 1 | Abierto en SPEC 7.2. Encaja en el workflow `ee-image` y, más adelante, en las imágenes de los servicios |
| Propuestas automáticas de actualización de digests | Al cerrar la fase 0, antes de la fase 1 | Abierto en SPEC 7.2. Siempre como PR, nunca aplicadas solas. Cubriría las actions fijadas por SHA, la imagen base de Ansible y las imágenes de los servicios |
| Validar las plantillas con Podman 6 | Cuando salga Fedora 45 | El job `quadlet-forward` del workflow `lint` ya valida con un Podman más nuevo (Fedora 44, Podman 5). Para Podman 6 basta con cambiar su imagen por el digest de `fedora:45` |
| Aprovechar Podman 5 o superior donde exista | Después de la fase 2, y solo con un servidor real con Podman 5+ en uso | Ansible lee la versión del servidor y usa `Notify=healthy` en el único sitio del patrón de espera (SPEC 4.3). El mínimo sigue siendo 4.9 (D5) |
| Límites de recursos parametrizados (memoria, CPU, procesos) | Fase 1, empezando por Postgres | Parámetros por servicio con valor por defecto, escritos en un único sitio de las plantillas. En 4.9: `PodmanArgs=--memory= --cpus=` y `PidsLimit=` (ver [`COMPATIBILITY.md`](COMPATIBILITY.md)). La fase 5 los endurece para los agentes. Nombres y valores por defecto se proponen en el PR de la fase 1 |
| Cargar los valores por defecto de los roles al validar plantillas | Fase 1 | `scripts/render-quadlets.yml` hoy solo usa `tests/quadlet/ci_vars.yml`; con roles reales tendrá que leer también sus `defaults/` |
