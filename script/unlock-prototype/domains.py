#!/usr/bin/env python3
"""HUMAN lab cleanup support: enumerate launchd GUI domains, print only domain targets.
No names, paths, credentials or raw launchctl output are emitted. Never bootouts a domain.
"""
import re
import subprocess
import sys


def children(text):
    match = re.search(r"(?m)^\s*subdomains = \{\n(.*?)^\s*\}", text, re.S)
    if not match:
        raise ValueError("Cannot parse launchctl subdomains; cleanup is unverified")
    result = []
    for line in match.group(1).splitlines():
        if not line.strip():
            continue
        child = re.fullmatch(r"\s*((?:pid|user|gui|login)/[0-9]+)\s*", line)
        if not child:
            raise ValueError("Unknown launchctl domain entry; cleanup is unverified")
        if not child[1].startswith("pid/"):
            result.append(child[1])
    return result


def domains():
    system = subprocess.run(["/bin/launchctl", "print", "system"], capture_output=True, text=True, check=True)
    pending = children(system.stdout)
    result = set()
    for domain in pending:
        if domain.startswith(("gui/", "login/")):
            result.add(domain)
        elif domain.startswith("user/"):
            # A domain can disappear during logout: conservatively fail rather than claim cleanup.
            user = subprocess.run(["/bin/launchctl", "print", domain], capture_output=True, text=True, check=True)
            result.update(d for d in children(user.stdout) if d.startswith(("gui/", "login/")))
    return sorted(result)


if __name__ == "__main__":
    try:
        print("\n".join(domains()))
    except (subprocess.SubprocessError, ValueError):
        print("Could not enumerate GUI domains; retry cleanup, do not call it clean.", file=sys.stderr)
        sys.exit(1)
