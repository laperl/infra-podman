"""Filters for the networking block of an instance (R59, docs/DECISIONS.md)."""
from __future__ import annotations

import ipaddress
import re

# Where roles/quadlet_deploy/templates/egress.network.j2 puts the networks with a limited
# way out: a destination must not fall inside it.
PLATFORM_RANGE = ipaddress.ip_network("10.90.0.0/16")


def egress_problems(value) -> list[str]:
    """What is wrong with a networking.egress value; an empty list when it is fine.

    Fine: false (no way out), true (everywhere), or a list with at least one IPv4 address
    or range, like ["100.64.0.7", "192.168.1.0/24"]. Names are not possible: the network
    of a limited way out has routes, not DNS.
    """
    if isinstance(value, bool):
        return []
    if not isinstance(value, (list, tuple)) or not value:
        return ["egress is true, false or a list with at least one IPv4 address or range"]
    problems = []
    for item in value:
        try:
            network = ipaddress.ip_network(str(item), strict=False)
        except ValueError:
            problems.append(f"{item} is not an IPv4 address or range (a name is not possible)")
            continue
        if network.version != 4:
            problems.append(f"{item} is not IPv4")
        elif network.prefixlen == 0:
            problems.append(f"{item} is everything: write egress: true instead")
        elif network.overlaps(PLATFORM_RANGE):
            problems.append(f"{item} overlaps {PLATFORM_RANGE}, which the platform uses for these networks")
    return problems


def instance_ids(apps, variables) -> list[str]:
    """Every instance declared for a machine, as <short>-<name>.

    apps: infra_apps (role -> short name). variables: the variables of the machine
    (hostvars[inventory_hostname]), where each role has its <role>_instances list.
    """
    return sorted(f"{short}-{instance['name']}" for role, short in apps.items()
                  for instance in (variables.get(f"{role}_instances") or []) if "name" in instance)


def _connects_to(instance) -> list:
    return list(((instance.get("networking") or {}).get("connects_to")) or [])


def clients_of(target, apps, variables) -> list[str]:
    """The instances of a machine that say networking.connects_to: [<target>].

    A connection is written once, by whoever starts it (R59): the other side reads it
    here. target: an identifier like pg-laptop.
    """
    return sorted(f"{short}-{instance['name']}" for role, short in apps.items()
                  for instance in (variables.get(f"{role}_instances") or [])
                  if "name" in instance and target in _connects_to(instance))


def is_postgres(ident, apps) -> bool:
    """Whether the identifier <short>-<name> is an instance of PostgreSQL."""
    return isinstance(ident, str) and ident.startswith(f"{apps.get('postgres', 'pg')}-")


def connects_to_problems(value, me, apps, variables) -> list[str]:
    """What is wrong with the networking.connects_to of the instance <me>; empty when fine.

    Fine: a list of identifiers of other instances of the same machine, each once, none
    of which says it connects to <me> (one line per pair: a network works both ways).
    PostgreSQL does not start connections: its instances write none (docs/NETWORK.md).
    """
    if not isinstance(value, (list, tuple)) or any(not isinstance(item, str) for item in value):
        return ["connects_to is a list of instances, like [pg-laptop]"]
    known = instance_ids(apps, variables)
    problems = []
    if value and is_postgres(me, apps):
        problems.append(f"{me} is PostgreSQL, which does not start connections: the application writes "
                        f"connects_to: [{me}] in its own instance")
    for target in sorted(set(value)):
        if list(value).count(target) > 1:
            problems.append(f"{target} is written more than once")
        if target == me:
            problems.append(f"{me} cannot connect to itself")
        elif target not in known:
            problems.append(f"{target} is not an instance of this machine (there are: {', '.join(known) or 'none'})")
        elif target in clients_of(me, apps, variables):
            problems.append(f"{target} already says it connects to {me}: one line per pair is enough, remove one of the two")
    return problems


def pairs_of(me, apps, variables) -> list[list[str]]:
    """Every pair [client, receiver] of the instance <me>: one network each (docs/NETWORK.md).

    <me> is the client of what its own connects_to names, and the receiver of whoever names
    <me> in theirs. Both sides work it out from the same inventory, so they agree.
    """
    mine = []
    for role, short in apps.items():
        for instance in variables.get(f"{role}_instances") or []:
            if f"{short}-{instance.get('name')}" == me:
                mine = [target for target in _connects_to(instance) if isinstance(target, str)]
    pairs = [[me, target] for target in mine] + [[client, me] for client in clients_of(me, apps, variables)]
    return [list(pair) for pair in sorted({tuple(pair) for pair in pairs if pair[0] != pair[1]})]


def pair_network(pair, env) -> str:
    """The name of the network of one pair: <env>-<client>-<receiver>-net (SPEC 4.12)."""
    return f"{env}-{pair[0]}-{pair[1]}-net"


def pair_units(pairs, env) -> list[dict]:
    """The quadlet_deploy items of the networks of these pairs, from the one common template
    (roles/quadlet_deploy/templates/pair.network.j2), labelled with the receiver."""
    return [{"template": "pair.network.j2", "common": True, "name": f"{pair_network(pair, env)}.network",
             "app": pair[1]} for pair in pairs]


DATABASE_RE = re.compile(r"^[a-z][a-z0-9_]{0,30}$")


def databases_of(target, apps, variables) -> list[str]:
    """The databases declared in the PostgreSQL instance <target> (pg-<name>) of a machine."""
    short = apps.get("postgres", "pg")
    for instance in variables.get("postgres_instances") or []:
        if isinstance(instance, dict) and f"{short}-{instance.get('name')}" == target:
            return [db["name"] for db in instance.get("databases") or [] if isinstance(db, dict) and "name" in db]
    return []


def pg_hba_problems(value, me, connects_to, apps, variables) -> list[str]:
    """What is wrong with the pg_hba of the instance <me>; empty when fine (docs/NETWORK.md).

    pg_hba says, for each PostgreSQL instance <me> connects to, which of its databases
    <me> enters: [{instance: pg-laptop, database: ff_casa}]. Every PostgreSQL instance of
    connects_to needs at least one; one that is not in connects_to has no network to come
    through, and a database must be declared in that instance (postgres_hosts.yml).
    """
    if value is None:
        value = []
    if not isinstance(value, (list, tuple)) or any(
            not isinstance(item, dict) or set(item) != {"instance", "database"}
            or not all(isinstance(item[key], str) for key in item) for item in value):
        return ["pg_hba is a list like [{instance: pg-laptop, database: ff_casa}], with only instance and database"]
    if value and is_postgres(me, apps):
        return [f"{me} is PostgreSQL: pg_hba is written by the application that connects to it"]
    known = instance_ids(apps, variables)
    targets = [target for target in (connects_to or []) if isinstance(target, str)]
    problems = []
    seen = []
    for item in value:
        key = (item["instance"], item["database"])
        if key in seen:
            problems.append(f"{item['instance']} {item['database']} is written more than once")
            continue
        seen.append(key)
        if not is_postgres(item["instance"], apps) or item["instance"] not in known:
            problems.append(f"{item['instance']} is not a PostgreSQL instance of this machine")
        elif item["instance"] not in targets:
            problems.append(f"{item['instance']} is in pg_hba but not in networking.connects_to: "
                            f"without connects_to: [{item['instance']}] there is no network to come through")
        if not DATABASE_RE.match(item["database"]):
            problems.append(f"{item['database']} is not a database name (^[a-z][a-z0-9_]{{0,30}}$)")
        elif is_postgres(item["instance"], apps) and item["instance"] in known:
            declared = databases_of(item["instance"], apps, variables)
            if item["database"] not in declared:
                problems.append(f"{item['database']} is not a database of {item['instance']} "
                                f"(there are: {', '.join(declared) or 'none'}): declare it in postgres_hosts.yml first")
    for target in targets:
        if is_postgres(target, apps) and target not in [item["instance"] for item in value]:
            problems.append(f"{target} is in connects_to and nothing in pg_hba says which of its databases: "
                            f"add {{instance: {target}, database: <its database>}}")
    return problems


def hba_of(target, apps, variables) -> list[dict]:
    """What the instances of a machine write in pg_hba for the PostgreSQL instance <target>.

    Only from instances that also connect to it (the rest has no network). Each item:
    {client: ff-casa, database: ff_casa}, sorted.
    """
    found = []
    for role, short in apps.items():
        for instance in variables.get(f"{role}_instances") or []:
            client = f"{short}-{instance.get('name')}"
            if target not in _connects_to(instance) or is_postgres(client, apps):
                continue
            for item in instance.get("pg_hba") or []:
                if isinstance(item, dict) and item.get("instance") == target and isinstance(item.get("database"), str):
                    found.append({"client": client, "database": item["database"]})
    unique = {(item["client"], item["database"]) for item in found}
    return [{"client": client, "database": database} for client, database in sorted(unique)]


def admins_of(target, apps, variables, admins) -> list[str]:
    """The instances of a machine that administer the PostgreSQL instance <target> (R37).

    Those of an application in <admins> (infra_postgres_admins) that say connects_to:
    [<target>]. The postgres role lets its superuser in from the network of each of these
    pairs, and no one else. Sorted.
    """
    shorts = [apps[role] for role in admins or [] if role in apps]
    return [client for client in clients_of(target, apps, variables)
            if any(client.startswith(f"{short}-") for short in shorts)]


class FilterModule:
    def filters(self):
        return {"egress_problems": egress_problems, "instance_ids": instance_ids,
                "clients_of": clients_of, "connects_to_problems": connects_to_problems,
                "is_postgres": is_postgres, "pairs_of": pairs_of, "pair_network": pair_network,
                "pair_units": pair_units, "databases_of": databases_of,
                "pg_hba_problems": pg_hba_problems, "hba_of": hba_of, "admins_of": admins_of}
