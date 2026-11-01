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

`deploy.sh` rechaza desplegar si el checkout no es un tag firmado válido. Su interfaz exacta se define en las fases 0 y 1.

## Versiones de los tags

`vMAYOR.MENOR.PARCHE`: sube el parche para correcciones, el menor para servicios o funciones nuevas y el mayor para cambios que rompen algo existente.

## Qué no hacer

- Pushear directamente a `main`.
- Desplegar desde una rama o desde un commit sin tag firmado.
- Dejar que una IA mergee, cree tags o ejecute `apply`.
