#!/usr/bin/env python3
"""Render vzrun results/<os>/<rev>.json into a Markdown table for
GITHUB_STEP_SUMMARY (and stdout). Usage: summary.py <results-dir>"""
import sys, json, glob, os

root = sys.argv[1] if len(sys.argv) > 1 else "results"
rows = []
for f in sorted(glob.glob(os.path.join(root, "*", "*.json"))):
    try:
        d = json.load(open(f))
    except Exception:
        continue
    rows.append(d)

def fmt(v):
    return "—" if v is None else (f"{v:.2f}s" if isinstance(v, (int, float)) else str(v))

order = {"freebsd": 0, "netbsd": 1, "linux": 2, "openbsd": 3}
rows.sort(key=lambda d: order.get(d.get("os"), 9))

out = []
out.append("| OS | rev | status | kernel→ready | total boot | dmesg lines | vCPU |")
out.append("|---|---|---|---:|---:|---:|---:|")
for d in rows:
    out.append("| {os} | `{rev}` | {st} | {k2r} | {tot} | {lines} | {cpu} |".format(
        os=d.get("os", "?"), rev=d.get("rev", "?"),
        st=("✅ " if d.get("status") == "ready" else "⚠️ ") + str(d.get("status")),
        k2r=fmt(d.get("kernel_to_ready_s")), tot=fmt(d.get("total_s")),
        lines=d.get("serial_lines", "—"), cpu=d.get("cpus", "—")))
table = "\n".join(out)
print(table)

sf = os.environ.get("GITHUB_STEP_SUMMARY")
if sf:
    with open(sf, "a") as fh:
        fh.write("## Boot-bench results\n\n" + table + "\n")
