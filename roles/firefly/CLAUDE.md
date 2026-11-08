# Rol `firefly`

Firefly III en un contenedor Quadlet sin root, sobre la Postgres de la plataforma. Requisitos: [`docs/services/firefly.md`](../../docs/services/firefly.md).

## Qué leer

- `docs/services/firefly.md`: qué tiene que cumplir y por qué.
- `docs/POSTGRES.md`, apartados 2 y 6: su base, su usuario y su red los crea el rol `postgres`, no este.
- SPEC 4.3 (espera a Postgres), 4.4 (red y puerto) y 4.14 (límites y lanzador).

## Qué no se toca

- **La red.** Solo `<entorno>-firefly-pg-<instancia>-net`, interna. Ni una segunda red ni `Network=host`: es lo que impide que tus finanzas salgan del portátil.
- **El puerto, solo en `127.0.0.1`** (R25).
- **El esquema y el usuario de Postgres**: los declara el operador en el repo de datos y los crea el rol `postgres`. Este rol solo comprueba que existen.
- **Los secretos, como ficheros** (`*_FILE`), nunca en `Environment=`.
- **`AUDIT_LOG_LEVEL=emergency`** (auditoría apagada): decisión del operador, 2026-11-08.
- **La espera con `ExecStartPre`**: no se cambia por `Notify=healthy` mientras haya Podman 4.9 (SPEC 4.3).

## Tests

- `lint`: renderiza `firefly.container` y su `.volume`, política y generador de Podman 4.9.
- `lifecycle`, job `firefly`, con `tests/lifecycle/check-firefly.sh`: rechazos claros sin secretos o con una clave de longitud mala; plan, apply, reaplicar y plan sin cambios; puerto, endurecimiento, esquema, `firefly_reader`, aislamiento, tareas diarias, lanzador, espera a Postgres, destruir conservando datos; y los bloques de Firefly de `docs/OPERATIONS.md`.
