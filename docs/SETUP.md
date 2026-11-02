# Puesta en marcha del portátil

Lo que se hace **una vez** en el nodo de control (Fedora Atomic 44, x86_64). Ningún paso necesita `rpm-ostree`: todo queda en tu usuario.

## 1. ansible-navigator

En un entorno virtual de Python de tu usuario. Todas sus dependencias tienen paquetes binarios para Python 3.14, así que no hace falta compilador (comprobado el 2026-11-02 para `ansible-navigator==26.10.0`).

```bash
python3 -m venv ~/.local/share/ansible-navigator
~/.local/share/ansible-navigator/bin/pip install ansible-navigator==26.10.0
ln -s ~/.local/share/ansible-navigator/bin/ansible-navigator ~/.local/bin/ansible-navigator
ansible-navigator --version
```

Ansible no se instala en el portátil: corre dentro de la imagen de Ansible.

## 2. Acceso a la imagen de Ansible en GHCR

La imagen es privada. Crea en GitHub un token **classic** con solo el permiso `read:packages` (Settings → Developer settings → Personal access tokens) y guárdalo en `infra-pro.kdbx`. Luego:

```bash
podman login ghcr.io --username laperl   # pega el token cuando lo pida
```

`podman login` guarda la credencial en `${XDG_RUNTIME_DIR}/containers/auth.json`, que se borra al reiniciar. Hay que repetirlo tras cada reinicio, o cuando `ansible-navigator` no pueda descargar la imagen.

## 3. Base de DEV

Con KeePassXC 2.8 crea `infra-dev.kdbx` **fuera del repo** (el `.gitignore` excluye `*.kdbx` igualmente):

- grupo `Infra_Podman`;
- entrada `test_dummy` con una contraseña ficticia cualquiera;
- contraseña maestra distinta de la de `infra-pro.kdbx`.

## 4. Prueba del lookup contra tu `.kdbx` (criterio de hecho de la fase 0)

Desde la raíz del repo, con la imagen del PR (su digest está en `ansible-navigator.yml`):

```bash
IMAGE=$(sed -n 's/^ *image: *\([^ ]*\).*/\1/p' ansible-navigator.yml)
KDBX=~/ruta/a/infra-dev.kdbx                      # cámbialo
read -rs -p 'Contraseña de infra-dev.kdbx: ' P; echo
printf '%s\n' "$P" | podman run --rm -i --user root \
  -v "$PWD:/work:ro,z" -w /work \
  -v "$KDBX:/kdbx/infra-dev.kdbx:ro,z" \
  "$IMAGE" bash -c 'IFS= read -r KDBX_PASSWORD; export KDBX_PASSWORD KDBX_DATABASE=/kdbx/infra-dev.kdbx; exec ansible-playbook tests/ee/operator_selftest.yml'
unset P
```

`--user root` hace falta porque, en Podman sin root, el root del contenedor es tu propio usuario en el portátil: así puede leer tu `.kdbx`, que normalmente solo tú puedes leer. ansible-navigator hace lo mismo.

Resultado esperado: `OK: read Infra_Podman/test_dummy (N characters)`. El valor no se muestra.

La contraseña viaja así: `read -s` (no se ve ni queda en el historial) → `printf`, que es una orden interna de bash y por tanto no aparece en la lista de procesos → entrada estándar del contenedor → variable de entorno solo dentro del contenedor → entrada estándar de `keepassxc-cli`. No toca el disco.

Más adelante, `deploy.sh secrets` (fase 0c) hará esto por ti.
