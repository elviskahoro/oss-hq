#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["kson-lang>=0.4.0"]
# ///
"""Small KSON CLI on top of the kson-lang Python bindings.

The upstream CLI (tooling/cli) is not published as a binary, so this wrapper
covers the common agent tasks: validate, format, and convert KSON <-> JSON/YAML.

Usage:
  ksonctl.py validate FILE... [--schema SCHEMA]
  ksonctl.py format FILE... [--style plain|delimited|compact|classic] [--indent N|--tabs] [--write|--check]
  ksonctl.py json FILE [--retain-tags]
  ksonctl.py yaml FILE [--retain-tags]

FILE may be "-" for stdin. Exit code 1 on any error, validation failure, or
(with --check) an unformatted file.
"""
import argparse
import sys
from pathlib import Path

from kson import (
    FormatOptions,
    FormattingStyle,
    IndentType,
    Kson,
    Result,
    SchemaResult,
    TranspileOptions,
)


def read(path: str) -> str:
    return sys.stdin.read() if path == "-" else Path(path).read_text()


def report(path: str, errors) -> None:
    for e in errors:
        pos = e.start()
        sev = e.severity().name if hasattr(e, "severity") else "ERROR"
        print(f"{path}:{pos.line() + 1}:{pos.column() + 1}: {sev}: {e.message()}", file=sys.stderr)


def cmd_validate(args) -> int:
    validator = None
    if args.schema:
        sr = Kson.parse_schema(read(args.schema))
        if not isinstance(sr, SchemaResult.Success):
            report(args.schema, sr.errors())
            return 1
        validator = sr.schema_validator()
    failed = False
    for f in args.files:
        src = read(f)
        errors = list(Kson.analyze(src, None, None).errors())
        report(f, errors)
        failed |= any(e.severity().name == "ERROR" for e in errors)
        if validator is not None and not failed:
            schema_errors = list(validator.validate(src, None))
            report(f, schema_errors)
            # The bindings tag schema violations as WARNING; any violation fails validation.
            failed |= bool(schema_errors)
    return 1 if failed else 0


def cmd_format(args) -> int:
    style = getattr(FormattingStyle, args.style.upper())
    indent = IndentType.Tabs() if args.tabs else IndentType.Spaces(args.indent)
    opts = FormatOptions(indent_type=indent, formatting_style=style, embed_block_rules=[])
    status = 0
    for f in args.files:
        src = read(f)
        errors = [e for e in Kson.analyze(src, None, None).errors() if e.severity().name == "ERROR"]
        if errors:
            report(f, errors)
            status = 1
            continue
        out = Kson.format(src, opts)
        if not out.endswith("\n"):
            out += "\n"
        if args.check:
            if out != src:
                print(f"{f}: not formatted", file=sys.stderr)
                status = 1
        elif args.write and f != "-":
            if out != src:
                Path(f).write_text(out)
        else:
            sys.stdout.write(out)
    return status


def cmd_transpile(args) -> int:
    src = read(args.file)
    if args.cmd == "json":
        r = Kson.to_json(src, TranspileOptions.Json(retain_embed_tags=args.retain_tags))
    else:
        r = Kson.to_yaml(src, TranspileOptions.Yaml(retain_embed_tags=args.retain_tags))
    if isinstance(r, Result.Success):
        out = r.output()
        sys.stdout.write(out if out.endswith("\n") else out + "\n")
        return 0
    report(args.file, r.errors())
    return 1


def main() -> int:
    p = argparse.ArgumentParser(prog="ksonctl.py", description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)

    v = sub.add_parser("validate", help="parse (and optionally schema-check) files")
    v.add_argument("files", nargs="+")
    v.add_argument("--schema", help="JSON Schema (Draft 7), written in KSON or JSON")
    v.set_defaults(func=cmd_validate)

    f = sub.add_parser("format", help="auto-format files")
    f.add_argument("files", nargs="+")
    f.add_argument("--style", default="plain", choices=["plain", "delimited", "compact", "classic"])
    f.add_argument("--indent", type=int, default=2)
    f.add_argument("--tabs", action="store_true")
    g = f.add_mutually_exclusive_group()
    g.add_argument("--write", "-w", action="store_true", help="rewrite files in place")
    g.add_argument("--check", action="store_true", help="exit 1 if any file is not formatted")
    f.set_defaults(func=cmd_format)

    for name in ("json", "yaml"):
        t = sub.add_parser(name, help=f"convert KSON (or JSON) to {name.upper()}")
        t.add_argument("file")
        t.add_argument("--retain-tags", action="store_true", help="keep embed blocks as {embedTag, embedContent}")
        t.set_defaults(func=cmd_transpile)

    args = p.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
