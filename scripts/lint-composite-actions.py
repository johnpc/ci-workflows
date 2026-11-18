#!/usr/bin/env python3
"""shellcheck every bash `run:` block of the composite actions (actionlint only
checks workflow files), with `${{ ... }}` expressions replaced by a placeholder."""
import glob
import re
import subprocess
import sys
import tempfile

import yaml

failed = False
for path in sorted(glob.glob("actions/*/action.yml")):
    doc = yaml.safe_load(open(path))
    for i, step in enumerate(doc["runs"].get("steps", [])):
        if "run" not in step or step.get("shell") != "bash":
            continue
        script = re.sub(r"\$\{\{.*?\}\}", "EXPR", step["run"])
        with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as f:
            f.write("#!/usr/bin/env bash\n" + script)
        r = subprocess.run(["shellcheck", "-x", f.name], capture_output=True, text=True)
        label = f"{path} step {i + 1} ({step.get('name', step.get('id', 'run'))})"
        if r.returncode:
            failed = True
            print(f"::error file={path}::shellcheck failed for {label}")
            print(r.stdout.replace(f.name, label))
        else:
            print(f"ok  {label}")
sys.exit(1 if failed else 0)
