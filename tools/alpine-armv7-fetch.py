#!/usr/bin/env python3
"""Resolve and fetch Alpine armv7 apk packages, following dependencies.

Alpine edge/main + edge/community, armv7. Only what is needed to *run* a
package is followed: "D:" entries that name a package or a so:/cmd: provider;
"m:"/"p:" are used to find providers when the dependency is a library name.
"""
import os, re, subprocess, sys, tarfile, io, urllib.request

ARCH = "armv7"
REPOS = [
    ("https://dl-cdn.alpinelinux.org/alpine/edge/main", "main"),
    ("https://dl-cdn.alpinelinux.org/alpine/edge/community", "community"),
]
CACHE = "/tmp/apkcache"
os.makedirs(CACHE, exist_ok=True)


def fetch(url, tag=""):
    path = os.path.join(CACHE, re.sub(r"[^A-Za-z0-9._-]", "_", url) + tag)
    if not os.path.exists(path):
        print("  get", url.rsplit("/", 1)[-1], file=sys.stderr)
        with urllib.request.urlopen(url, timeout=120) as r, open(path, "wb") as f:
            f.write(r.read())
    return path


class Repo:
    def __init__(self):
        self.pkgs = {}      # name -> block dict
        self.provides = {}  # "so:libz.so.1" / "cmd:x" -> name
        for base, label in REPOS:
            url = f"{base}/{ARCH}/APKINDEX.tar.gz"
            data = fetch(url, "@" + label)
            with tarfile.open(data) as t:
                txt = t.extractfile("APKINDEX").read().decode()
            for blk in txt.split("\n\n"):
                p = self._parse(blk)
                if p:
                    p["_repo"] = base
                    self.pkgs[p["P"]] = p
                    for prov in p.get("p", "").split():
                        self.provides.setdefault(prov.split("=")[0], p["P"])

    @staticmethod
    def _parse(blk):
        if not re.search(r"^P:", blk, re.M):
            return None
        out = {}
        for line in blk.splitlines():
            m = re.match(r"^([A-Za-z~]):(.*)$", line)
            if m:
                k, v = m.group(1), m.group(2)
                out[k] = (out.get(k, "") + " " + v).strip()
        return out

    def resolve(self, roots):
        seen, order, queue = set(), [], list(roots)
        while queue:
            name = queue.pop(0)
            if name in seen:
                continue
            pkg = self.pkgs.get(name)
            if not pkg:
                prov = self.provides.get(name)
                if prov:
                    pkg = self.pkgs[prov]
                    name = prov
                else:
                    print(f"  !! no provider for {name}", file=sys.stderr)
                    continue
            seen.add(name)
            order.append(pkg)
            for dep in pkg.get("D", "").split():
                d = re.split(r"[=<~>]", dep)[0]
                if d.startswith("so:") or d.startswith("cmd:"):
                    # provided by another package, resolved through self.provides
                    queue.append(d)
                elif d in self.pkgs or d in self.provides:
                    queue.append(d)
                elif re.match(r"^[a-z0-9]", d):
                    queue.append(d)
        return order


def _safe(member, dest):
    """Extraction filter.

    apk payloads contain symlinks that point outside the tree (Alpine's
    ca-certificates does: etc/ssl1.1/cert.pem -> /etc/ca-certificates/...).
    They are irrelevant here and would be a path-escape, so they are skipped
    rather than materialised. Everything else is extracted as-is.
    """
    if member.issym() or member.islnk():
        target = member.linkname
        if os.path.isabs(target) or ".." in target.split("/"):
            return None
    return member


def extract(pkg, dest):
    url = f"{pkg.get('_repo', REPOS[0][0])}/{ARCH}/{pkg['P']}-{pkg['V']}.apk"
    path = fetch(url)
    with tarfile.open(path) as t:
        for m in t.getmembers():
            if m.name.startswith("."):
                continue
            if _safe(m, dest) is None:
                continue
            try:
                t.extract(m, dest, filter="tar")
            except (tarfile.OutsideDestinationError, OSError):
                # a symlink or odd entry we do not need; the files we do need
                # are all regular files or tree-local symlinks
                continue
    return pkg["P"]


if __name__ == "__main__":
    dest, roots = sys.argv[1], sys.argv[2:]
    repo = Repo()
    pkgs = repo.resolve(roots)
    total, done = 0, set()
    for p in pkgs:
        if p["P"] in done:
            continue
        done.add(p["P"])
        name = extract(p, dest)
        size = int(p.get("I", 0))
        total += size
        print(f"  {name:26} {p['V']:18} {size/1e6:6.1f} MB installed")
    print(f"  {'TOTAL':26} {'':18} {total/1e6:6.1f} MB installed")
