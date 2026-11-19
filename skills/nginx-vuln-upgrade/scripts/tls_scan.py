#!/usr/bin/env python3
"""tls_scan.py — TLS 逐版本握手扫描（openssl s_client 子进程）。

用法:
    tls_scan.py <host> <port> [sni] [openssl_path]
    openssl_path 缺省用 PATH 里的 openssl；验证 TLS 1.3 必须用 >= 1.1.1 的版本
    （EL7 自带 1.0.2 验不了 1.3，且其 `Protocol :` 打印的是请求版本，不能当证据）。

判定口径（避免旧客户端误判坑）:
- 逐版本 tls1 / tls1.1 / tls1.2 / tls1.3 各发一次握手；
- 以 `New, ...` cipher 行判定: `New, (NONE)` = 拒绝；有 cipher = 成功；
- `Verify return code` 忽略（本扫描只验协议放行，不验证书链）。

输出: 表格（host:port, sni, 每版本 OK/拒绝），末尾一行 openssl 版本。
"""

import subprocess
import sys

VERSIONS = [("TLS1.0", "-tls1"), ("TLS1.1", "-tls1_1"),
            ("TLS1.2", "-tls1_2"), ("TLS1.3", "-tls1_3")]


def probe(openssl, host, port, sni, flag, timeout=10):
    cmd = [openssl, "s_client", flag, "-connect", f"{host}:{port}", "-brief"]
    if sni:
        cmd += ["-servername", sni]
    try:
        p = subprocess.run(cmd, input=b"", capture_output=True, timeout=timeout)
        blob = (p.stdout + p.stderr).decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        return "no(timeout)"
    # 判定: cipher 行 "New, (NONE)" = 握手被拒; 出现实际 cipher = 成功
    for line in blob.splitlines():
        s = line.strip()
        if "New, (NONE)" in s:
            return "rejected"
        if s.startswith("Protocol_version") or s.startswith("New,"):
            return "ok"
        if s.startswith("New, ") and "(NONE)" not in s:
            return "ok"
    if "handshake failure" in blob.lower() or "no protocols available" in blob.lower():
        return "rejected"
    return "no"


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    host, port = sys.argv[1], sys.argv[2]
    sni = sys.argv[3] if len(sys.argv) > 3 else None
    openssl = sys.argv[4] if len(sys.argv) > 4 else "openssl"

    res = []
    for label, flag in VERSIONS:
        res.append(f"{label}={probe(openssl, host, port, sni, flag)}")
    ver = subprocess.run([openssl, "version"], capture_output=True).stdout.decode().strip()
    print(f"+{'-'*28}+{'-'*32}+{'-'*12}+")
    print(f"| {'target':<26} | {'sni':<30} | {'verdict':<10} |")
    print(f"+{'-'*28}+{'-'*32}+{'-'*12}+")
    print(f"| {f'{host}:{port}':<26} | {sni or '-':<30} | {'scan':<10} |")
    print(f"+{'-'*28}+{'-'*32}+{'-'*12}+")
    for (label, _), r in zip(VERSIONS, res):
        print(f"| {label:<26} | {'':<30} | {r.split('=', 1)[1]:<10} |")
    print(f"+{'-'*28}+{'-'*32}+{'-'*12}+")
    print(f"# oneliner: {host}:{port} sni={sni or '-'}  " + "  ".join(res) + f"  [{ver}]")


if __name__ == "__main__":
    main()
