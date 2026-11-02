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
| Escáner de vulnerabilidades en CI | Al cerrar la fase 0, antes de la fase 1 | Abierto en SPEC 7.2. Encaja en el workflow `ee-image` y, más adelante, en las imágenes de los servicios |
| Propuestas automáticas de actualización de digests | Al cerrar la fase 0, antes de la fase 1 | Abierto en SPEC 7.2. Siempre como PR, nunca aplicadas solas. Cubriría las actions fijadas por SHA, la imagen base de Ansible y las imágenes de los servicios |
| Validar las plantillas también con el generador de Podman 6 | Fase 0, en cuanto se tenga el digest de `fedora:44` | Para detectar a tiempo lo que deje de funcionar al actualizar Podman. No cambia las plantillas |
| Aprovechar Podman 5 o superior donde exista | Después de la fase 2, y solo con un servidor real con Podman 5+ en uso | Ansible lee la versión del servidor y usa `Notify=healthy` en el único sitio del patrón de espera (SPEC 4.3). El mínimo sigue siendo 4.9 (D5) |
| Límites de memoria sin `Memory=` | Fase 5 | Quadlet 4.9 no tiene `Memory=`. Elegir entre `PodmanArgs=--memory=` y `MemoryMax=` (ver [`COMPATIBILITY.md`](COMPATIBILITY.md)) |
| Cargar los valores por defecto de los roles al validar plantillas | Fase 1 | `scripts/render-quadlets.yml` hoy solo usa `tests/quadlet/ci_vars.yml`; con roles reales tendrá que leer también sus `defaults/` |
