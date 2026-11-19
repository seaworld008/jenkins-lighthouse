#!/usr/bin/env python3
"""scan-job-commands.py - inventory what Jenkins jobs actually depend on (read-only).

Usage:
  scan-job-commands.py JOBS_DIR [--json | --csv] [--include-disabled]
  scan-job-commands.py JOBS_DIR --base-images [--workspace WORKSPACE_DIR] [--include-disabled]

JOBS_DIR is <JENKINS_HOME>/jobs. Folders are followed recursively; build records are not read.

For every job it reports the type, disabled flag, JDK / NodeJS tool, label, triggers, SCM URLs and branches,
and - from shell steps and inline pipeline scripts - the commands used, whether /etc/profile is sourced,
hard-coded absolute path prefixes, SSH/SCP targets, image registries and Dockerfile FROM images.

--base-images prints "<image><TAB><number of jobs>" for every FROM image found in inline scripts and, with
--workspace, in Dockerfiles under <WORKSPACE_DIR>/<job>/ (depth <= 4). Feed it to find-missing-base-images.sh.

Credentials embedded in SCM URLs are masked. Script bodies are never printed.
Python 3.6+, standard library only.
"""
import argparse
import collections
import csv
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

TOOLS = ["mvn", "gradle", "ant", "java", "npm", "npx", "yarn", "pnpm", "node", "docker", "docker-compose",
         "kubectl", "helm", "rsync", "scp", "ssh", "sshpass", "php", "composer", "git", "svn", "curl", "wget",
         "obsutil", "ossutil", "aws", "python", "python3", "zip", "unzip", "tar", "sudo", "expect"]
TOOL_RX = re.compile(r"(?:^|[\s;&|(`$]|&&|\|\|)(%s)(?=$|[\s;&|)`])" % "|".join(re.escape(t) for t in sorted(TOOLS, key=len, reverse=True)), re.M)
PROFILE_RX = re.compile(r"(?:^|[\s;&])(?:source|\.)\s+/etc/profile\b", re.M)
ABS_RX = re.compile(r"(?<![\w.:/-])(/(?:data|opt|root|home|srv|mnt|var/lib/jenkins|usr/local|app|apps|web|www)(?:/[\w.@+-]+){0,2})")
SSH_RX = re.compile(r"\b(?:ssh|sshpass\b[^\n]*?\bssh)\b([^\n;|&]*)")
SCP_RX = re.compile(r"\b(?:scp|rsync)\b[^\n;|&]*?\s((?:[\w.-]+@)?[\w.-]+):[^\s]*")
USERHOST_RX = re.compile(r"(?<![\w.-])([\w.-]+@[\w.-]+|(?:\d{1,3}\.){3}\d{1,3})(?![\w.-])")
DOCKER_REF_RX = re.compile(r"\bdocker\s+(?:push|pull|login|tag)\s+(?:-\S+\s+)*([^\s;|&]+)")
FROM_RX = re.compile(r"^\s*FROM\s+(?:--platform=\S+\s+)?([^\s#]+)", re.M | re.I)
URL_CRED_RX = re.compile(r"(://)[^/@\s]+@")


def parse_xml(path):
    with open(path, "rb") as f:
        data = f.read()
    # Jenkins writes XML 1.1 declarations, which ElementTree refuses to parse.
    data = re.sub(rb"^<\?xml[^>]*\?>", b"", data.lstrip(), count=1)
    try:
        return ET.fromstring(data)
    except ET.ParseError:
        return None


def find_jobs(jobs_dir):
    """Yield (full_name, config_path, job_dir). Recurses into folder-like items via their own jobs/ dir."""
    if not os.path.isdir(jobs_dir):
        return
    for name in sorted(os.listdir(jobs_dir)):
        d = os.path.join(jobs_dir, name)
        cfg = os.path.join(d, "config.xml")
        if not os.path.isfile(cfg):
            continue
        sub = os.path.join(d, "jobs")
        if os.path.isdir(sub):
            for full, c, jd in find_jobs(sub):
                yield name + "/" + full, c, jd
            root = parse_xml(cfg)
            if root is not None and "folder" in root.tag.lower():
                continue
        yield name, cfg, d


def texts(root, tag):
    return [e.text for e in root.iter() if e.tag.rsplit(".", 1)[-1] == tag and e.text] if root is not None else []


def first(root, tag):
    v = texts(root, tag)
    return v[0].strip() if v else ""


def registry_of(ref):
    head = ref.split("/", 1)[0]
    if "/" in ref and ("." in head or ":" in head or head == "localhost"):
        return head
    return ""


def analyse_script(s, out):
    for m in TOOL_RX.finditer(s):
        out["commands"].add(m.group(1))
    if PROFILE_RX.search(s):
        out["sources_profile"] = True
    for m in ABS_RX.finditer(s):
        out["abs_paths"].add(m.group(1).rstrip("."))
    for m in SSH_RX.finditer(s):
        for h in USERHOST_RX.findall(m.group(1)):
            out["remote_targets"].add(h)
    for m in SCP_RX.finditer(s):
        out["remote_targets"].add(m.group(1))
    for m in DOCKER_REF_RX.finditer(s):
        ref = m.group(1)
        reg = ref if "/" not in ref and ("." in ref or ":" in ref) else registry_of(ref)
        if reg and "$" not in reg:
            out["registries"].add(reg)
    for m in FROM_RX.finditer(s):
        img = m.group(1)
        if not img.startswith("$") and img.lower() != "scratch":
            out["from_images"].add(img)


def scan_job(full, cfg):
    root = parse_xml(cfg)
    info = {
        "name": full,
        "type": root.tag if root is not None else "UNPARSEABLE",
        "disabled": first(root, "disabled") == "true",
        "jdk": first(root, "jdk"),
        "nodejs": first(root, "nodeJSInstallationName"),
        "label": first(root, "assignedNode"),
        "triggers": [],
        "scm_urls": sorted({URL_CRED_RX.sub(r"\1****@", u.strip()) for u in texts(root, "url")
                            if re.match(r"^(https?|ssh|git)://|^[\w.-]+@[\w.-]+:", u.strip())}),
        "branches": sorted({(e.findtext("name") or "").strip() for e in (root.iter() if root is not None else [])
                            if e.tag.endswith("BranchSpec") and (e.findtext("name") or "").strip()}),
        "script_path": first(root, "scriptPath"),
        "commands": set(), "sources_profile": False, "abs_paths": set(), "remote_targets": set(),
        "registries": set(), "from_images": set(),
    }
    if root is not None:
        trig = root.find("triggers")
        if trig is None:
            for p in root.iter():
                if p.tag.endswith("PipelineTriggersJobProperty"):
                    trig = p.find("triggers")
        if trig is not None:
            info["triggers"] = sorted({t.tag.rsplit(".", 1)[-1] for t in trig})
        for tag in ("command", "script"):
            for s in texts(root, tag):
                analyse_script(s, info)
    for k in ("commands", "abs_paths", "remote_targets", "registries", "from_images"):
        info[k] = sorted(info[k])
    return info


def workspace_from_images(ws_dir, job_name):
    found = set()
    base = os.path.join(ws_dir, job_name.replace("/", os.sep))
    if not os.path.isdir(base):
        return found
    base_depth = base.rstrip(os.sep).count(os.sep)
    for d, dirs, files in os.walk(base):
        if d.count(os.sep) - base_depth >= 4:
            dirs[:] = []
        dirs[:] = [x for x in dirs if x not in (".git", "node_modules", "target", "vendor", "dist")]
        for f in files:
            if f == "Dockerfile" or f.startswith("Dockerfile.") or f.endswith(".Dockerfile"):
                try:
                    with open(os.path.join(d, f), encoding="utf-8", errors="replace") as fh:
                        for m in FROM_RX.finditer(fh.read()):
                            img = m.group(1)
                            if not img.startswith("$") and img.lower() != "scratch":
                                found.add(img)
                except OSError:
                    pass
    return found


def summary(jobs, out):
    enabled = [j for j in jobs if not j["disabled"]]
    w = out.write
    w("jobs: %d (enabled %d, disabled %d)\n" % (len(jobs), len(enabled), len(jobs) - len(enabled)))
    w("types: %s\n" % dict(collections.Counter(j["type"] for j in jobs).most_common()))
    w("\n[enabled jobs only below]\n")
    w("source /etc/profile: %d\n" % sum(j["sources_profile"] for j in enabled))
    maven = [j["name"] for j in enabled if j["type"] == "maven2-moduleset"]
    w("maven project type (bound to controller Java, see pitfalls A4): %d %s\n" % (len(maven), maven[:20]))
    for key, title in (("jdk", "JDK tool"), ("nodejs", "NodeJS tool"), ("label", "label")):
        w("%s: %s\n" % (title, dict(collections.Counter(j[key] or "-" for j in enabled).most_common())))
    w("triggers: %s\n" % dict(collections.Counter(t for j in enabled for t in j["triggers"]).most_common()))
    for key, title in (("commands", "commands"), ("abs_paths", "absolute path prefixes"),
                       ("remote_targets", "ssh/scp/rsync targets"), ("registries", "image registries"),
                       ("from_images", "inline FROM images")):
        c = collections.Counter(v for j in enabled for v in j[key])
        w("\n%s (%d distinct):\n" % (title, len(c)))
        for v, n in c.most_common(40):
            w("  %5d  %s\n" % (n, v))
        if len(c) > 40:
            w("  ... %d more (use --json)\n" % (len(c) - 40))
    missing_branch = [j["name"] for j in enabled if j["scm_urls"] and not j["branches"] and not j["script_path"]]
    if missing_branch:
        w("\njobs with SCM but no recognisable branch spec: %d\n" % len(missing_branch))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("jobs_dir")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--json", action="store_true", help="one JSON document with every job")
    g.add_argument("--csv", action="store_true", help="one CSV row per job")
    g.add_argument("--base-images", action="store_true", help="FROM images used by jobs")
    ap.add_argument("--workspace", help="with --base-images: also read Dockerfiles in WORKSPACE/<job>/")
    ap.add_argument("--include-disabled", action="store_true")
    a = ap.parse_args(argv)
    if not os.path.isdir(a.jobs_dir):
        ap.error("not a directory: %s" % a.jobs_dir)
    jobs = [scan_job(full, cfg) for full, cfg, _ in find_jobs(a.jobs_dir)]
    if a.base_images:
        use = collections.defaultdict(set)
        for j in jobs:
            if j["disabled"] and not a.include_disabled:
                continue
            imgs = set(j["from_images"])
            if a.workspace:
                imgs |= workspace_from_images(a.workspace, j["name"])
            for i in imgs:
                use[i].add(j["name"])
        for img in sorted(use):
            print("%s\t%d" % (img, len(use[img])))
        return 0
    if not a.include_disabled and (a.json or a.csv):
        jobs = [j for j in jobs if not j["disabled"]]
    if a.json:
        json.dump(jobs, sys.stdout, ensure_ascii=False, indent=1)
        sys.stdout.write("\n")
    elif a.csv:
        cols = ["name", "type", "disabled", "jdk", "nodejs", "label", "triggers", "scm_urls", "branches", "script_path",
                "commands", "sources_profile", "abs_paths", "remote_targets", "registries", "from_images"]
        wr = csv.writer(sys.stdout)
        wr.writerow(cols)
        for j in jobs:
            wr.writerow([" ".join(j[c]) if isinstance(j[c], list) else j[c] for c in cols])
    else:
        summary(jobs, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
