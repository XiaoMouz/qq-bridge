"""创建独立解密环境：pnpm --filter @qqbridge/server imports:setup。"""
import os
from pathlib import Path
import subprocess
import venv

root = Path(__file__).resolve().parents[3] / '.backup-import-venv'
venv.EnvBuilder(with_pip=True).create(root)
python = root / ('Scripts/python.exe' if os.name == 'nt' else 'bin/python')
subprocess.run([str(python), '-m', 'pip', 'install', '-r', str(Path(__file__).with_name('requirements.txt'))], check=True)
print('BACKUP_IMPORT_PYTHON=' + str(python))
