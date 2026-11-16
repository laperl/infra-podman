#!/usr/bin/env python3
"""What runs on this machine and whether it is well: the report of the check playbook.

Read-only, as the service user (playbooks/check.yml). It asks Podman and the service
user's systemd, reads the backup configuration and its status files, and prints one
report for the operator, in Spanish, ending with a summary line. Nothing here knows any
application by name: everything is found by the labels every unit of the platform carries
(infra.managed-by, infra.app; docs/NAMING.md, section 6).

Input, as JSON in the environment variable MACHINE_REPORT_INPUT:
  host      name of the machine in the inventory
  env       dev | prod
  declared  the instances the inventory declares for this machine, as <short>-<name>,
            and "backup"
  secrets   names of the Podman secrets the inventory installs on this machine
"""
from __future__ import annotations

import glob
import json
import os
import subprocess
import sys

STATUS_DIR = os.environ.get("INFRA_BACKUP_STATUS_DIR", "/var/lib/infra-podman/backup-status")
MANAGED = "label=infra.managed-by=infra-podman"


# What could not be read. A report that says "none" because a command failed would be a
# lie: every failure ends here and report() shows it as a problem.
ERRORS: list[str] = []


def run(*argv: str) -> str:
    """Output of a command. A failure is noted in ERRORS and gives an empty string."""
    try:
        done = subprocess.run(argv, capture_output=True, text=True, check=False, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as error:
        ERRORS.append(f"«{' '.join(argv[:3])}» no se pudo ejecutar: {error}")
        return ""
    if done.returncode != 0:
        reason = (done.stderr.strip().splitlines() or ["sin mensaje"])[-1]
        ERRORS.append(f"«{' '.join(argv[:3])}» falló ({done.returncode}): {reason}")
        return ""
    return done.stdout


def run_json(*argv: str) -> list:
    out = run(*argv)
    try:
        return json.loads(out or "[]") or []
    except ValueError:
        ERRORS.append(f"«{' '.join(argv[:3])}» no devolvió JSON")
        return []


def unit_properties(unit: str) -> dict:
    """ActiveState, Result and the times of a unit of the service user's systemd."""
    out = run("systemctl", "--user", "show", unit,
              "--property=ActiveState,Result,NextElapseUSecRealtime,LastTriggerUSec")
    return dict(line.split("=", 1) for line in out.splitlines() if "=" in line)


def read_lines(path: str) -> list[str]:
    try:
        with open(path, encoding="utf-8") as handle:
            return [line.strip() for line in handle if line.strip() and not line.startswith("#")]
    except OSError:
        return []


def collect() -> dict:
    """Everything the report needs, as plain data: what report() takes."""
    home = os.path.expanduser("~")
    # Ansible starts the script in a folder of the user it connects as, and rootless Podman
    # refuses to run from a folder its user cannot enter.
    os.chdir(home)
    quadlets = os.path.join(home, ".config/containers/systemd")
    units = os.path.join(home, ".config/systemd/user")
    backup = os.path.join(home, ".config/infra-podman/backup")
    timers = sorted(os.path.basename(path) for path in glob.glob(os.path.join(units, "*.timer")))
    # The services of the platform: one per Quadlet container, and the plain ones a timer
    # starts (the scheduled tasks of an application).
    services = sorted({os.path.basename(path)[: -len(".container")] + ".service"
                       for path in glob.glob(os.path.join(quadlets, "*.container"))}
                      | {os.path.basename(path) for path in glob.glob(os.path.join(units, "*.service"))})
    status = {}
    for path in sorted(glob.glob(os.path.join(STATUS_DIR, "*.status"))):
        status[os.path.basename(path)[: -len(".status")]] = dict(
            line.split("=", 1) for line in read_lines(path) if "=" in line)
    data = {
        "containers": run_json("podman", "ps", "--all", "--filter", MANAGED, "--format", "json"),
        "volumes": run_json("podman", "volume", "ls", "--filter", MANAGED, "--format", "json"),
        "networks": run_json("podman", "network", "ls", "--filter", MANAGED, "--format", "json"),
        "secrets": run("podman", "secret", "ls", "--format", "{{.Name}}").split(),
        "timers": {timer: unit_properties(timer) for timer in timers},
        "services": {service: unit_properties(service) for service in services},
        "backup_items": read_lines(os.path.join(backup, "backup.conf")) + [
            line for path in sorted(glob.glob(os.path.join(backup, "backup.d", "*.conf")))
            for line in read_lines(path)],
        "backup_files": [os.path.basename(path)[: -len(".conf")]
                         for path in sorted(glob.glob(os.path.join(backup, "backup.d", "*.conf")))],
        "backup_status": status,
    }
    # podman ps does not tell a container without network from one on Podman's default
    # network, which has a way out: its network mode does.
    for container in data["containers"]:
        container["NetworkMode"] = run("podman", "inspect", "--format", "{{.HostConfig.NetworkMode}}",
                                       container.get("Id", "")).strip()
    data["errors"] = list(ERRORS)
    return data


def label(item: dict, name: str) -> str:
    return ((item.get("Labels") or item.get("labels") or {}).get(name)) or ""


def short_image(image: str) -> str:
    """registry/name@sha256:0123456789ab, without the rest of the digest."""
    name, _, digest = image.partition("@")
    return f"{name}@{digest[:19]}" if digest else name


def container_line(container: dict) -> tuple[str, str]:
    """(text, problem): how one container is, and what is wrong with it, if anything."""
    name = (container.get("Names") or ["?"])[0]
    state = container.get("State", "?")
    status = container.get("Status", "")
    if state != "running":
        health, problem = f"PARADO ({state})", f"{name} no está en marcha ({state})"
    elif "(unhealthy)" in status:
        health, problem = "en marcha, NO SANO", f"{name} está en marcha pero su comprobación de salud falla"
    elif "(starting)" in status:
        health, problem = "en marcha, arrancando", ""
    elif "(healthy)" in status:
        health, problem = "en marcha, sano", ""
    else:
        health, problem = "en marcha (sin comprobación de salud)", ""
    ports = ", ".join(f"{port.get('host_ip') or '0.0.0.0'}:{port.get('host_port')}->{port.get('container_port')}"
                      for port in container.get("Ports") or []) or "ninguna"
    mode = container.get("NetworkMode") or "?"
    networks = ", ".join(container.get("Networks") or []) or (
        "ninguna (sin red)" if mode == "none" else f"la de Podman por defecto, CON SALIDA ({mode})")
    text = (f"{name}: {health}. Entrada: {ports}. Redes: {networks}. "
            f"Imagen: {short_image(container.get('Image', '?'))}")
    return text, problem


def network_kind(network: dict) -> str:
    """Where a network lets its containers go, as Podman has it now (not as its unit says)."""
    if network.get("internal"):
        return "interna (sin salida)"
    if (network.get("options") or {}).get("no_default_route") == "true":
        routes = ", ".join(route.get("destination", "?") for route in network.get("routes") or [])
        dns = ", CON DNS" if network.get("dns_enabled") else ", sin DNS"
        return f"salida SOLO a {routes or 'ningún sitio'}{dns}"
    return "CON SALIDA A TODO (internet y red local)"


def describe_item(line: str) -> str:
    """One line of backup.conf or backup.d, in words."""
    kind, _, rest = line.partition(" ")
    words = rest.split()
    if kind == "pg" and len(words) >= 2:
        return f"{words[0]}: todas sus bases, una por una (pg_dump en {words[1]})"
    if kind == "file" and len(words) >= 3:
        return f"{words[0]}: el fichero {words[2]} ({words[1]})"
    if kind == "volume" and len(words) >= 3:
        return f"{words[0]}: el volumen {words[2]} entero ({words[1]})"
    if kind == "exec" and len(words) >= 4:
        return f"{words[0]}: lo que imprime «{' '.join(words[3:])}» en {words[2]} ({words[1]})"
    return f"línea que no se entiende: {line}"


def report(data: dict, host: str, env: str, declared: list[str], secrets: list[str]) -> tuple[list[str], list[str]]:
    """The lines of the report and the list of problems."""
    lines: list[str] = [f"=== {host} ({env}) ==="]
    problems: list[str] = []
    containers = sorted(data["containers"], key=lambda item: (item.get("Names") or [""])[0])
    if data.get("errors"):
        lines.append("NO SE HA PODIDO LEER (lo que sigue está incompleto: no te fíes de un «ninguno»)")
        lines.extend(f"  {error}" for error in data["errors"])
        problems.extend(f"no se pudo leer: {error}" for error in data["errors"])

    lines.append("SERVICIOS (contenedores de la plataforma)")
    for container in containers:
        text, problem = container_line(container)
        lines.append(f"  {text}")
        if problem:
            problems.append(problem)
    running_apps = {label(container, "infra.app") for container in containers}
    for instance in sorted(set(declared) - {"backup"} - running_apps):
        lines.append(f"  FALTA {instance}: está en el inventario y no tiene contenedor")
        problems.append(f"{instance} está declarada y no tiene contenedor")
    if not containers and not set(declared) - {"backup"}:
        lines.append("  ninguno")

    # A service that is neither running nor started by a timer is one that failed or was
    # stopped by hand: a timer's own service sleeps between runs, and that is normal.
    # A container that exists and is stopped is already listed above.
    running_names = {(container.get("Names") or [""])[0] for container in containers}
    timed = {timer[: -len(".timer")] for timer in data["timers"]}
    for service, properties in sorted(data["services"].items()):
        stem = service[: -len(".service")]
        if stem in running_names or stem in timed:
            continue
        state = properties.get("ActiveState", "?")
        lines.append(f"  {service}: NO ESTÁ EN MARCHA ({state})")
        problems.append(f"{service} no está en marcha ({state})")

    lines.append("TAREAS PROGRAMADAS (temporizadores del usuario de servicio)")
    for timer, properties in sorted(data["timers"].items()):
        active = properties.get("ActiveState", "?")
        service = data["services"].get(timer[: -len(".timer")] + ".service") or {}
        last_result = service.get("Result") or "?"
        last_text = {"success": "bien", "?": "?"}.get(last_result, f"MAL ({last_result})")
        lines.append(f"  {timer}: {'activo' if active == 'active' else 'INACTIVO (' + active + ')'}. "
                     f"Próxima: {properties.get('NextElapseUSecRealtime') or 'sin fecha'}. "
                     f"Última: {properties.get('LastTriggerUSec') or 'nunca'}"
                     + (f". La última terminó: {last_text}" if service else ""))
        if active != "active":
            problems.append(f"el temporizador {timer} no está activo ({active})")
        if service and last_result not in ("success", "?"):
            problems.append(f"la última ejecución de {timer[: -len('.timer')]}.service terminó mal ({last_result})")
    if not data["timers"]:
        lines.append("  ninguna")

    lines.append("REDES")
    for network in sorted(data["networks"], key=lambda item: item.get("name", "")):
        subnets = ", ".join(subnet.get("subnet", "?") for subnet in network.get("subnets") or [])
        kind = network_kind(network)
        lines.append(f"  {network.get('name')}: {kind}, {subnets or 'sin subred'} (de {label(network, 'infra.app') or '?'})")
    if not data["networks"]:
        lines.append("  ninguna")

    lines.append("VOLÚMENES (datos)")
    for volume in sorted(data["volumes"], key=lambda item: item.get("Name", "")):
        lines.append(f"  {volume.get('Name')} (de {label(volume, 'infra.app') or '?'})")
    if not data["volumes"]:
        lines.append("  ninguno")

    lines.append("COPIAS")
    if data["backup_items"]:
        lines.append("  Qué copia el backup diario de esta máquina:")
        lines.extend(f"    {describe_item(item)}" for item in data["backup_items"])
    else:
        lines.append("  Esta máquina no tiene backup configurado (playbook backup).")
    for unit, status in sorted(data["backup_status"].items()):
        result = status.get("result", "?")
        lines.append(f"  {unit}: resultado {result}, última buena {status.get('last_ok') or 'nunca'}"
                     + (f", ocupa {status['usage']}" if status.get("usage") else "")
                     + (f". {status['message']}" if result != "ok" and status.get("message") else ""))
        if result == "failed":
            problems.append(f"{unit}: la última copia falló")

    # A volume is in the backup when a line names it, or when its instance is copied with
    # its own tool (pg). The backup's own volumes are the copy itself.
    words = [item.split() for item in data["backup_items"]]
    copied = {item[3] for item in words if item[0] == "volume" and len(item) > 3}
    dumped = {item[1] for item in words if item[0] == "pg" and len(item) > 1} | {"backup"}
    for volume in sorted(data["volumes"], key=lambda item: item.get("Name", "")):
        if volume.get("Name") not in copied and label(volume, "infra.app") not in dumped:
            lines.append(f"  FUERA DE LA COPIA: el volumen {volume.get('Name')} (de {label(volume, 'infra.app') or '?'})")

    lines.append("SECRETOS")
    missing = sorted(set(secrets) - set(data["secrets"]))
    lines.append(f"  {len(secrets)} declarados para esta máquina, {len(secrets) - len(missing)} instalados")
    for name in missing:
        lines.append(f"  FALTA {name} (./deploy.sh secrets)")
        problems.append(f"falta el secreto {name}")

    leftovers: list[str] = []
    for kind, items, key in (("contenedor", containers, "Names"), ("volumen", data["volumes"], "Name"),
                             ("red", data["networks"], "name")):
        for item in items:
            app = label(item, "infra.app")
            if app not in declared:
                name = item.get(key)
                leftovers.append(f"{kind} {name[0] if isinstance(name, list) else name} (de {app or '?'})")
    leftovers += [f"secreto {name} (no está en infra_secrets)" for name in sorted(data["secrets"])
                  if name.startswith(f"{env}-") and name not in secrets]
    leftovers += [f"copias de {name} (fichero en backup.d)" for name in data["backup_files"] if name not in declared]
    lines.append("SOBRA (está en la máquina y el inventario no lo declara; no se toca nada)")
    lines.extend(f"  {item}" for item in leftovers)
    if not leftovers:
        lines.append("  nada")

    if problems:
        lines.append(f"RESUMEN: {len(problems)} PROBLEMA(S)")
        lines.extend(f"  - {problem}" for problem in problems)
    else:
        lines.append("RESUMEN: todo correcto")
    return lines, problems


def main() -> int:
    given = json.loads(os.environ.get("MACHINE_REPORT_INPUT") or "{}")
    lines, _ = report(collect(), given.get("host", "?"), given.get("env", "?"),
                      given.get("declared", []), given.get("secrets", []))
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
