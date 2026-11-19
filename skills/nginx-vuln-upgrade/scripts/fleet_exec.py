#!/usr/bin/env python3
"""fleet_exec.py — 通用批量执行器（SSH）。

用法:
    fleet_exec.py <script.sh> <tag> <host[,host2,...]> [timeout]
    host 传 "all" 时对 inventory 全部主机执行。

inventory 从 JSON 文件读（默认与本脚本同目录 inventory.json，可用环境变量
FLEET_INVENTORY 指定路径），格式见 inventory.example.json:
    {"alias": {"host": "192.0.2.10", "port": 22, "user": "root"}}

行为（与 nginx CVE 批量升级实践的口径一致）:
- 脚本经 base64 编码后在远端 `bash -s` 执行，避免引号/编码问题。
- 每台输出落盘 outdir/<alias>.<tag>.txt，首行含 rc 与主机信息，事后可审计。
- 任一台 rc != 0（或连接/执行失败）立即停止后续主机: 先灰度单台再批量，
  失败自动停，不放大事故。需要"尽力跑完"时设环境变量 FLEET_KEEP_GOING=1。
- 仅使用 SSH 密钥/agent 认证，不读取、不保存任何密码。

依赖: paramiko (pip install paramiko)。
"""

import base64
import concurrent.futures as cf
import hashlib
import json
import os
import sys
import time
from pathlib import Path

import paramiko

HERE = Path(__file__).resolve().parent
OUTDIR = Path(os.environ.get("FLEET_OUTDIR", HERE / "outdir"))
INVENTORY = Path(os.environ.get("FLEET_INVENTORY", HERE / "inventory.json"))
MAX_WORKERS = int(os.environ.get("FLEET_WORKERS", "8"))
KEEP_GOING = os.environ.get("FLEET_KEEP_GOING", "") == "1"


def load_inventory():
    if not INVENTORY.exists():
        sys.exit(f"inventory not found: {INVENTORY} (see inventory.example.json)")
    inv = json.loads(INVENTORY.read_text(encoding="utf-8"))
    for alias, s in inv.items():
        s.setdefault("port", 22)
        s.setdefault("user", "root")
    return inv


def connect(s):
    c = paramiko.SSHClient()
    c.load_system_host_keys()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(
        s["host"], port=int(s["port"]), username=s["user"],
        timeout=20, banner_timeout=30, auth_timeout=30,
        allow_agent=True, look_for_keys=True,   # 仅密钥/agent 认证，无密码
    )
    return c


def run(c, cmd, timeout):
    _, stdout, stderr = c.exec_command(cmd, timeout=timeout, get_pty=False)
    out = stdout.read().decode("utf-8", "replace")
    err = stderr.read().decode("utf-8", "replace")
    return stdout.channel.recv_exit_status(), out, err


def one(alias, s, script, tag, timeout):
    """单台执行；返回 (alias, rc, 概要)。失败时已把现场写入输出文件。"""
    OUTDIR.mkdir(parents=True, exist_ok=True)
    outfile = OUTDIR / f"{alias}.{tag}.txt"
    try:
        c = connect(s)
    except Exception as e:
        outfile.write_text(f"# {alias} {s['host']}:{s['port']} rc=-1 CONNECT_FAIL\n"
                           f"{type(e).__name__}: {e}\n", encoding="utf-8")
        return alias, -1, f"CONNECT_FAIL {type(e).__name__}: {e}"
    try:
        fp = "SHA256:" + base64.b64encode(
            hashlib.sha256(c.get_transport().get_remote_server_key().asbytes()).digest()
        ).decode().rstrip("=")
        b64 = base64.b64encode(script.encode()).decode()
        rc, out, err = run(c, f"echo {b64} | base64 -d | bash -s", timeout)
        text = (f"# {alias} {s['host']}:{s['port']} hostkey={fp} rc={rc} "
                f"ts={time.strftime('%Y-%m-%d %H:%M:%S')}\n{out}\n--- stderr ---\n{err}")
        outfile.write_text(text, encoding="utf-8")
        return alias, rc, f"rc={rc}"
    except Exception as e:
        outfile.write_text(f"# {alias} {s['host']}:{s['port']} rc=-2 RUN_FAIL\n"
                           f"{type(e).__name__}: {e}\n", encoding="utf-8")
        return alias, -2, f"RUN_FAIL {type(e).__name__}: {e}"
    finally:
        c.close()


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    script = Path(sys.argv[1]).read_text(encoding="utf-8").replace("\r\n", "\n")
    tag = sys.argv[2]
    sel = sys.argv[3]
    timeout = int(sys.argv[4]) if len(sys.argv) > 4 else 300

    inv = load_inventory()
    if sel == "all":
        targets = list(inv.items())
    else:
        names = [x.strip() for x in sel.split(",") if x.strip()]
        missing = [n for n in names if n not in inv]
        if missing:
            sys.exit(f"unknown host(s) in inventory: {','.join(missing)}")
        targets = [(n, inv[n]) for n in names]

    failed = 0
    with cf.ThreadPoolExecutor(MAX_WORKERS) as ex:
        futs = {ex.submit(one, a, s, script, tag, timeout): a for a, s in targets}
        for fut in cf.as_completed(futs):
            alias, rc, summary = fut.result()
            print(f"{alias}: {summary} -> {OUTDIR / (alias + '.' + tag + '.txt')}", flush=True)
            if rc != 0:
                failed += 1
                print(f"STOP: {alias} failed (rc={rc}); 先单台排查，再灰度重试。"
                      f"（设 FLEET_KEEP_GOING=1 可继续）", flush=True)
                if not KEEP_GOING:
                    for f in futs:
                        f.cancel()
                    sys.exit(1)
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
