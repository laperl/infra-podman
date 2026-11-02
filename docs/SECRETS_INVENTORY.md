# Inventario de secretos

Lista de los secretos que usa la plataforma (SPEC 4.5). **Nunca valores**: solo nombres, dónde están y quién los usa.

- Copia maestra en producción: `infra-pro.kdbx`, en el portátil.
- DEV: `infra-dev.kdbx`, con las mismas rutas y valores ficticios.
- Ruta de cada entrada: `Infra_Podman/<nombre>`.
- Las bases `.kdbx` nunca entran en el repo, ni siquiera la de DEV (`.gitignore` las excluye).
- `infra-dev.kdbx` es desechable: solo existe en el portátil y se recrea con los nombres de `infra_secrets` (`inventory/dev/group_vars/all.yml`). No se copia a la VM ni se le hace copia de seguridad (R17).

| Nombre del secreto en Podman | Ruta en KeePassXC | Consumidores | Rotación |
| --- | --- | --- | --- |
| `test_dummy` | `Infra_Podman/test_dummy` | Solo pruebas del lookup `kdbx.py` (fase 0). Solo existe en `infra-dev.kdbx` | No aplica |

Al añadir un secreto: fila nueva aquí en el mismo PR que lo usa.
