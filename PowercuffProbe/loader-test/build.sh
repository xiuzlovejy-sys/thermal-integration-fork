set -eu
test_sources="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
if [ "$#" -ne 2 ]; then
    printf 'Usage: sh build.sh /path/to/apple-artifact.zip /absolute/output/directory\n' >&2
    exit 2
fi
test_archive="$1"
test_output="$2"
case "$test_output" in
    /*) ;;
    *) printf 'Output directory must be absolute\n' >&2; exit 2 ;;
esac
if [ -e "$test_output" ]; then
    printf 'Output directory already exists; use a new directory\n' >&2
    exit 2
fi
python3 - "$test_archive" "$test_output" "$test_sources" <<'PY'
from pathlib import Path
import hashlib
import json
import shutil
import struct
import sys
import zipfile

archive_path, output_path, source_path = map(Path, sys.argv[1:])
stage = output_path / "stage"
payload = stage / "usr/lib/jycharge-powercuff-loader-test"
(stage / "DEBIAN").mkdir(parents=True)
payload.mkdir(parents=True)
record = {"archive_sha256": hashlib.sha256(archive_path.read_bytes()).hexdigest(), "inputs": {}}
with zipfile.ZipFile(archive_path) as archive:
    for name in ("host", "observer.dylib", "controller"):
        data = archive.read("host-checks/" + name)
        magic, cpu, subtype, filetype = struct.unpack_from("<4I", data)
        expected_type = 6 if name == "observer.dylib" else 2
        if (magic, cpu, subtype, filetype) != (0xFEEDFACF, 0x0100000C, 0x80000002, expected_type):
            raise SystemExit("Unexpected input architecture or file type: " + name)
        (payload / name).write_bytes(data)
        (payload / name).chmod(0o755)
        record["inputs"][name] = hashlib.sha256(data).hexdigest()
shutil.copyfile(source_path / "control", stage / "DEBIAN/control")
for name in ("README.md", "run-tests.sh"):
    shutil.copyfile(source_path / name, payload / name)
(payload / "run-tests.sh").chmod(0o755)
(payload / "BUILD.json").write_text(json.dumps(record, indent=2) + "\n")
PY
test_payload="$test_output/stage/usr/lib/jycharge-powercuff-loader-test"
ldid -S"$test_sources/host.entitlements" "$test_payload/host"
ldid -S"$test_sources/host.entitlements" "$test_payload/controller"
ldid -S "$test_payload/observer.dylib"
dpkg-deb --build --root-owner-group "$test_output/stage" \
    "$test_output/com.jy.charge.powercuff-loader-test_0.1.0_iphoneos-arm64e.deb"
