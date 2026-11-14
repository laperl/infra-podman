# Rol `firefly`

Firefly III en contenedores Quadlet sin root, sobre la Postgres de la plataforma, **por instancias** (R48): `playbooks/firefly.yml` aplica el rol una vez por cada elemento de `firefly_instances`. Requisitos: [`docs/services/firefly.md`](../../docs/services/firefly.md); lo común a toda aplicación: [`docs/services/README.md`](../../docs/services/README.md).

## Qué leer

- `docs/services/firefly.md`: qué tiene que cumplir y por qué.
- `docs/POSTGRES.md`, apartados 2 y 6: su base, su usuario y su red los crea el rol `postgres`, no este.
- SPEC 4.3 (espera a Postgres), 4.4 (red y puerto) y 4.14 (límites y lanzador).

## Qué no se toca

- **El nombre corto `ff`** (`firefly_short`, R49): todo lo que se crea en la máquina es `<entorno>-ff-<instancia>`, `ff_<instancia>`… En el código y el inventario, `firefly`. No es un ajuste del inventario.
- **Nada compartido entre instancias**: cada nombre lleva la instancia (`defaults/main.yml`, «Names»). Una base de datos por instancia, nunca un esquema dentro de la base de otra.
- **La red.** Solo la suya, `<entorno>-ff-<instancia>-pg-<postgres>-net`, interna. Ni una segunda red ni `Network=host`: es lo que impide que tus finanzas salgan del portátil.
- **La entrada la escribe el operador** en `inbound.publish` (R55), y va tal cual a `PublishPort=`; el rol no pone direcciones ni puertos por su cuenta. El comando del navegador del lanzador, como lista de palabras comprobadas: nada que entrecomillar.
- **El esquema y el usuario de Postgres**: los declara el operador en el repo de datos y los crea el rol `postgres`. Este rol solo comprueba que existen.
- **Los secretos, como ficheros** (`*_FILE`), nunca en `Environment=`.
- **`AUDIT_LOG_LEVEL=emergency`** (auditoría apagada): decisión del operador, 2026-11-08.
- **La espera con `ExecStartPre`**: no se cambia por `Notify=healthy` mientras haya Podman 4.9 (SPEC 4.3).

## Tests

- `lint`: renderiza `firefly.container` y su `.volume`, política y generador de Podman 4.9.
- `lifecycle`, job `firefly`, con `tests/lifecycle/check-firefly.sh` y dos instancias (`casa` y `canary`, con otra imagen, otra memoria y otro navegador): rechazos claros (nombres o puertos repetidos, comando del navegador peligroso, sin secretos, clave de longitud mala); plan, apply, reaplicar y plan sin cambios; puerto, endurecimiento, base propia, `_reader`, aislamiento también entre instancias, primer usuario, tareas diarias, lanzadores, espera a Postgres; una instancia quitada del inventario solo se avisa; retirar una sin tocar la otra; destruir conservando datos; y los bloques de Firefly de `docs/OPERATIONS.md`.
