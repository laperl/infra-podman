"""Filters for the networking block of an instance (R59, docs/DECISIONS.md)."""
from __future__ import annotations

import ipaddress

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


def connects_to_problems(value, me, apps, variables) -> list[str]:
    """What is wrong with the networking.connects_to of the instance <me>; empty when fine.

    Fine: a list of identifiers of other instances of the same machine, each once, none
    of which says it connects to <me> (one line per pair: a network works both ways).
    """
    if not isinstance(value, (list, tuple)) or any(not isinstance(item, str) for item in value):
        return ["connects_to is a list of instances, like [pg-laptop]"]
    known = instance_ids(apps, variables)
    problems = []
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


class FilterModule:
    def filters(self):
        return {"egress_problems": egress_problems, "instance_ids": instance_ids,
                "clients_of": clients_of, "connects_to_problems": connects_to_problems}
