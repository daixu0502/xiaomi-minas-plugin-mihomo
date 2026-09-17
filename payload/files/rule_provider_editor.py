#!/usr/bin/env python3
import re
import sys
from pathlib import Path


TOP_LEVEL = re.compile(r"^[A-Za-z0-9_-]+:\s*.*$")


def section_bounds(lines, key):
    start = None
    for index, line in enumerate(lines):
        if re.match(rf"^{re.escape(key)}:\s*(?:#.*)?$", line.rstrip("\n")):
            start = index
            break
    if start is None:
        return None
    end = len(lines)
    for index in range(start + 1, len(lines)):
        if TOP_LEVEL.match(lines[index].rstrip("\n")):
            end = index
            break
    return start, end


def yaml_single_quote(value):
    return "'" + value.replace("'", "''") + "'"


def update_provider(lines, name, url, behavior, fmt, via):
    suffix = "mrs" if fmt == "mrs" else "yaml"
    block = [
        f"  {name}:\n",
        "    type: http\n",
        f"    behavior: {behavior}\n",
        f"    format: {fmt}\n",
        f"    url: {yaml_single_quote(url)}\n",
        f"    path: ./rules/app-{name}.{suffix}\n",
        "    interval: 86400\n",
        f"    proxy: {via}\n",
    ]
    bounds = section_bounds(lines, "rule-providers")
    if bounds is None:
        if lines and lines[-1].strip():
            lines.append("\n")
        lines.extend(["rule-providers:\n", *block])
        return lines

    start, end = bounds
    provider_start = None
    provider_pattern = re.compile(rf"^  {re.escape(name)}:\s*(?:#.*)?$")
    for index in range(start + 1, end):
        if provider_pattern.match(lines[index].rstrip("\n")):
            provider_start = index
            break
    if provider_start is None:
        lines[end:end] = block
        return lines

    provider_end = end
    next_provider = re.compile(r"^  [A-Za-z0-9_.-]+:\s*(?:#.*)?$")
    for index in range(provider_start + 1, end):
        if next_provider.match(lines[index].rstrip("\n")):
            provider_end = index
            break
    lines[provider_start:provider_end] = block
    return lines


def update_rules(lines, name, target):
    rule = f"  - RULE-SET,{name},{target}\n"
    bounds = section_bounds(lines, "rules")
    if bounds is None:
        if lines and lines[-1].strip():
            lines.append("\n")
        lines.extend(["rules:\n", rule, "  - MATCH,DIRECT\n"])
        return lines

    start, end = bounds
    existing = re.compile(rf"^\s*-\s*RULE-SET\s*,\s*{re.escape(name)}\s*,")
    body = [line for line in lines[start + 1 : end] if not existing.match(line)]
    insert_at = len(body)
    for index, line in enumerate(body):
        if re.match(r"^\s*-\s*MATCH\s*,", line):
            insert_at = index
            break
    body.insert(insert_at, rule)
    lines[start + 1 : end] = body
    return lines


def main():
    if len(sys.argv) != 9:
        raise SystemExit("invalid arguments")
    source, target_file, name, url, behavior, fmt, action, via = sys.argv[1:]
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}", name):
        raise SystemExit("invalid provider name")
    lines = Path(source).read_text(encoding="utf-8").splitlines(keepends=True)
    lines = update_provider(lines, name, url, behavior, fmt, via)
    lines = update_rules(lines, name, action)
    Path(target_file).write_text("".join(lines), encoding="utf-8")


if __name__ == "__main__":
    main()
