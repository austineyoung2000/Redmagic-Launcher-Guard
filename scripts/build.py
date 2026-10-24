#!/usr/bin/env python3
"""Build the manager-installable module without network dependencies."""
from pathlib import Path
import zipfile
root = Path(__file__).resolve().parents[1]
module = root / 'module'
version = dict(line.split('=', 1) for line in (module / 'module.prop').read_text().splitlines())['version']
out = root / 'dist' / f'Redmagic-Launcher-Guard-{version}.zip'
out.parent.mkdir(exist_ok=True)
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(module.rglob('*')):
        if path.is_file():
            info = zipfile.ZipInfo(path.relative_to(module).as_posix(), (2026, 1, 1, 0, 0, 0))
            info.external_attr = (0o100755 if path.suffix == '.sh' or path.name == 'update-binary' else 0o100644) << 16
            archive.writestr(info, path.read_bytes(), compress_type=zipfile.ZIP_DEFLATED)
print(out)
