#!/usr/bin/env python3
"""Run default scanners and print gegenlesen command JSONL on stdout."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

WORKSPACE = Path("/workspace")
MAX_FINDINGS = 200
MAX_SNIPPET = 4096
PLANTED_PARTS = {
    "testdata",
    "fixtures",
    "mocks",
    "__mocks__",
    "snapshots",
    "examples",
    "example",
}


def main() -> int:
    findings: list[dict] = []
    emit_gitleaks(findings)
    emit_osv(findings)
    emit_checks(findings)
    for row in findings[:MAX_FINDINGS]:
        sys.stdout.write(json.dumps(row, separators=(",", ":")) + "\n")
    return 0


def emit_gitleaks(findings: list[dict]) -> None:
    report = Path("/tmp/gitleaks.json")
    cmd = [
        "gitleaks",
        "dir",
        str(WORKSPACE),
        "--no-banner",
        "--report-format",
        "json",
        "--report-path",
        str(report),
        "--exit-code",
        "0",
    ]
    run_ignore(cmd)
    if not report.is_file():
        cmd = [
            "gitleaks",
            "detect",
            "--source",
            str(WORKSPACE),
            "--no-git",
            "--report-format",
            "json",
            "--report-path",
            str(report),
            "--exit-code",
            "0",
        ]
        run_ignore(cmd)
    if not report.is_file():
        return
    try:
        payload = json.loads(report.read_text(encoding="utf-8") or "[]")
    except json.JSONDecodeError:
        return
    if isinstance(payload, dict):
        rows = payload.get("findings") or payload.get("leaks") or []
    else:
        rows = payload
    if not isinstance(rows, list):
        return
    for item in rows:
        if not isinstance(item, dict):
            continue
        path = relpath(item.get("File") or item.get("file") or "")
        if not path or planted(path):
            continue
        start = int(item.get("StartLine") or item.get("start_line") or 1)
        end = int(item.get("EndLine") or item.get("end_line") or start)
        snippet = str(item.get("Match") or item.get("Secret") or item.get("Snippet") or "").strip()
        if not snippet:
            snippet = line_slice(path, start, end)
        if not snippet:
            continue
        rule = str(item.get("RuleID") or item.get("Rule") or "secret")
        desc = str(item.get("Description") or item.get("Message") or "Possible secret")
        findings.append(
            finding(
                scanner="gitleaks",
                requires_judge=False,
                title=f"Secret: {rule}",
                message=desc,
                severity="error",
                file_path=path,
                start_line=max(start, 1),
                end_line=max(end, start, 1),
                snippet=clip(snippet),
            )
        )


def emit_osv(findings: list[dict]) -> None:
    cmd = [
        "osv-scanner",
        "scan",
        "source",
        "-r",
        "--format",
        "json",
        str(WORKSPACE),
    ]
    proc = run_capture(cmd)
    if proc.returncode not in (0, 1) or not proc.stdout.strip():
        cmd = ["osv-scanner", "scan", "-r", "--format", "json", str(WORKSPACE)]
        proc = run_capture(cmd)
    if not proc.stdout.strip():
        return
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return
    results = payload.get("results") if isinstance(payload, dict) else None
    if not isinstance(results, list):
        return
    for result in results:
        if not isinstance(result, dict):
            continue
        source = result.get("source") if isinstance(result.get("source"), dict) else {}
        path = relpath(str(source.get("path") or ""))
        if not path or planted(path):
            continue
        packages = result.get("packages") or []
        if not isinstance(packages, list):
            continue
        for pkg in packages:
            if not isinstance(pkg, dict):
                continue
            meta = pkg.get("package") if isinstance(pkg.get("package"), dict) else {}
            name = str(meta.get("name") or "")
            version = str(meta.get("version") or "")
            vulns = pkg.get("vulnerabilities") or []
            if not isinstance(vulns, list):
                continue
            for vuln in vulns:
                if not isinstance(vuln, dict):
                    continue
                vid = str(vuln.get("id") or "CVE")
                summary = str(vuln.get("summary") or vuln.get("details") or vid).split("\n", 1)[0]
                start, snippet = snippet_for_package(path, name, version)
                findings.append(
                    finding(
                        scanner="osv-scanner",
                        requires_judge=False,
                        title=f"{vid} in {name or path}",
                        message=f"{name}@{version} is affected by {vid}. {summary}".strip(),
                        severity="error",
                        file_path=path,
                        start_line=start,
                        end_line=start,
                        snippet=clip(snippet),
                    )
                )


def emit_checks(findings: list[dict]) -> None:
    checks = Path("/checks")
    if not checks.is_dir():
        return
    for script in sorted(checks.iterdir()):
        if not script.is_file() or not os.access(script, os.X_OK):
            continue
        if script.name.startswith("."):
            continue
        proc = run_capture([str(script)])
        if proc.returncode != 0:
            continue
        name = slug(script.stem)
        for line in proc.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(row, dict):
                continue
            row["scanner"] = f"check-{name}"
            row.setdefault("requires_judge", True)
            if planted(str(row.get("file_path") or "")):
                continue
            findings.append(row)


def snippet_for_package(path: str, name: str, version: str) -> tuple[int, str]:
    target = WORKSPACE / path
    needles = [part for part in (name, name.split("/")[-1], version) if part]
    try:
        text = target.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return 1, name or path
    lines = text.splitlines() or [""]
    for index, line in enumerate(lines, start=1):
        if any(needle and needle in line for needle in needles):
            return index, line
    return 1, lines[0]


def finding(
    *,
    scanner: str,
    requires_judge: bool,
    title: str,
    message: str,
    severity: str,
    file_path: str,
    start_line: int,
    end_line: int,
    snippet: str,
) -> dict:
    return {
        "title": title[:200],
        "message": message[:4000],
        "severity": severity,
        "file_path": file_path,
        "start_line": start_line,
        "end_line": end_line,
        "snippet": snippet,
        "scanner": scanner,
        "requires_judge": requires_judge,
    }


def planted(path: str) -> bool:
    parts = Path(path).parts
    if len(parts) >= 2 and parts[0] == "evals" and parts[1] == "cases":
        return True
    return any(part.lower() in PLANTED_PARTS for part in parts)


def relpath(raw: str) -> str:
    text = raw.replace("\\", "/").strip()
    for prefix in ("/workspace/", "./"):
        if text.startswith(prefix):
            text = text[len(prefix) :]
    return text.lstrip("/")


def line_slice(path: str, start: int, end: int) -> str:
    target = WORKSPACE / path
    try:
        lines = target.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return ""
    lo = max(start - 1, 0)
    hi = min(max(end, start), len(lines))
    if lo >= len(lines):
        return ""
    return "\n".join(lines[lo:hi])


def clip(text: str) -> str:
    data = text.encode("utf-8")
    if len(data) <= MAX_SNIPPET:
        return text
    return data[:MAX_SNIPPET].decode("utf-8", errors="ignore")


def slug(name: str) -> str:
    chars = []
    for ch in name.lower():
        if ch.isalnum():
            chars.append(ch)
        elif not chars or chars[-1] != "-":
            chars.append("-")
    text = "".join(chars).strip("-") or "check"
    return text[:80]


def run_ignore(cmd: list[str]) -> None:
    subprocess.run(
        cmd,
        cwd=WORKSPACE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


def run_capture(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        cwd=WORKSPACE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )


if __name__ == "__main__":
    raise SystemExit(main())
