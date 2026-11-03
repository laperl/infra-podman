# Flujo de trabajo del operador

Cómo se hace cada cambio, siempre igual. Regla de oro: **nada entra en `main` sin PR, y nada se despliega sin tag firmado.**

## 1. Pedir el cambio

Abre una conversación con Claude con este repo conectado y pide la tarea en una frase, por ejemplo:

> Implementa la fase 1 según `docs/SPEC.md`.

Claude crea una rama y abre un PR en borrador. Si no puede abrirlo, te da el enlace para abrirlo tú en un clic.

## 2. Revisar el PR en GitHub

1. Pestaña **Pull requests** → abre el PR.
2. Espera a que el CI esté en verde (existe a partir de la fase 0).
3. Pestaña **Files changed**: revisa lo que entra.
4. Si algo no te gusta, coméntalo en el PR o pídeselo a Claude. La corrección llega como **commit nuevo en el mismo PR**. Nunca abras un PR nuevo para lo mismo ni edites `main` directamente.

También puedes editar tú un fichero del PR con el lápiz de GitHub, eligiendo **Commit directly to the `<rama>` branch**.

## 3. Mergear

1. Si el PR está en borrador: **Ready for review**.
2. Botón verde → **Squash and merge** → **Confirm**.
3. La rama se borra sola.

## 4. Desplegar (a partir de la fase 1)

En el portátil, con el agente SSH de KeePassXC desbloqueado:

```bash
git switch main && git pull
git tag -s v0.1.0 -m "descripción del cambio"   # tag firmado con tu clave SSH
git push origin v0.1.0
./deploy.sh plan <playbook>                      # lee el plan con calma
./deploy.sh apply <playbook>                     # solo si el plan es lo esperado
```

`plan` y `apply` piden siempre la contraseña de sudo (`BECOME password:`); si el playbook no la necesita, pulsa Intro. Si la del portátil y la del GX10 son distintas, despliega cada máquina con `--limit laptop` o `--limit gx10` (R24).

`deploy.sh` rechaza desplegar en producción si el checkout no está limpio o si `HEAD` no tiene un tag firmado por una clave de `~/.config/infra-podman/allowed_signers`. `apply` en producción pide además que escribas `prod`.

### Probar un PR en DEV antes del merge

```bash
git fetch origin && git switch <rama-del-PR> && git pull
./deploy.sh plan <playbook> --env dev
./deploy.sh apply <playbook> --env dev      # lo lanzas tú; opencode solo ejecuta pruebas
```

En DEV no hace falta tag. Si en DEV ves algo raro, coméntalo en el PR antes de mergear.

### Las órdenes de `deploy.sh`

| Orden | Qué hace |
| --- | --- |
| `./deploy.sh plan <playbook> [--env dev\|prod] [--limit HOSTS]` | Simula (`--check --diff`) y enseña qué cambiaría |
| `./deploy.sh apply <playbook> [--env dev\|prod] [--limit HOSTS]` | Aplica |
| `./deploy.sh secrets [--env dev\|prod] [--rotate NOMBRE]` | Pide la contraseña de KeePassXC y gestiona los secretos (en la fase 0 solo comprueba que se pueden leer) |

`--env` vale `prod` si no lo pones. Cada ejecución deja una línea en `~/.local/state/infra-podman/deploy.log` con fecha, entorno, acción, playbook, tag o rama, hosts y resultado.

## Versiones de los tags

`vMAYOR.MENOR.PARCHE`: sube el parche para correcciones, el menor para servicios o funciones nuevas y el mayor para cambios que rompen algo existente.

## Qué no hacer

- Pushear directamente a `main`.
- Desplegar desde una rama o desde un commit sin tag firmado.
- Dejar que una IA mergee, cree tags o ejecute `apply`.
