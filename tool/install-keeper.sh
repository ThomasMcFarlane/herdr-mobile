#!/bin/sh
# Installs the keeper for the desktop terminal client (herdr-tui) on a machine where the
# herdr mobile app never installed it. It is the same python file the app pushes over
# SSH, extracted from app/lib/data/services/keeper_script.dart with the agent table filled in.
#
#   tool/install-keeper.sh            -> ~/.herdr-mobile/desktop/keeper-desktop.py
#
# Why a separate path: the app installs ~/.herdr-mobile/keeper-<hash>.py and removes other
# versions' files, so a copy placed there would be deleted. Needs python3.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
src="$here/../app/lib/data/services/keeper_script.dart"
routes="$here/../rust/crates/keeper/routes.json"
dest="${HOME}/.herdr-mobile/desktop"
mkdir -p "$dest"
chmod 700 "${HOME}/.herdr-mobile" "$dest"
python3 - "$src" "$routes" "$dest/keeper-desktop.py" <<'PY'
import json, os, sys
src, routes, out = sys.argv[1:4]
text = open(src, encoding="utf-8").read()
body = text.split("const keeperPython = r'''\n", 1)[1].rsplit("\n''';", 1)[0]
table = json.dumps(json.load(open(routes)), separators=(",", ":"))
tmp = out + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.write(body.replace("@@ROUTES@@", table) + "\n")
os.chmod(tmp, 0o700)
os.replace(tmp, out)
print("installed", out)
PY
