#!/usr/bin/env python3
"""Run satty with the argv area-screenshot-annotate builds, plus --help.

Exits with satty's status: clap rejects unknown or extra arguments before it
gets to --help, so a non-zero exit means the script would never open Satty.
Usage: satty-args-check.py <path to area-screenshot-annotate>
"""
import ast
import subprocess
import sys

tree = ast.parse(open(sys.argv[1]).read())
for node in ast.walk(tree):
    if (isinstance(node, ast.Call) and getattr(node.func, "attr", "") == "run"
            and node.args and isinstance(node.args[0], ast.List)):
        argv = [e.value if isinstance(e, ast.Constant) else "/tmp/satty-test.png"
                for e in node.args[0].elts]
        break
else:
    sys.exit("no subprocess.run([...]) call found")

print(" ".join(argv))
sys.exit(subprocess.run(argv + ["--help"], stdout=subprocess.DEVNULL).returncode)
