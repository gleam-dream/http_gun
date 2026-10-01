"""Small executable package boundary checks; no sibling checkout is required."""
from pathlib import Path
import tomllib

root = Path(__file__).resolve().parent.parent
config = tomllib.loads((root / "gleam.toml").read_text())
allowed = {"gleam_stdlib", "gleam_http", "gleam_erlang", "gleam_otp", "gleam_json", "gun", "cowlib", "file_streams", "simplifile", "sinal"}
assert set(config["dependencies"]) == allowed
assert config["dependencies"]["sinal"] == {"path": "../sinal"}
assert all(isinstance(value, str) for name, value in config["dependencies"].items() if name != "sinal")
lock = tomllib.loads((root / "manifest.toml").read_text())
versions = {p["name"]: p["version"] for p in lock["packages"]}
assert versions["gun"] == "2.6.0" and versions["cowlib"] == "2.20.0"
assert versions["file_streams"] == "1.7.0" and versions["simplifile"] == "2.7.0"
for path in (root / "src").rglob("*.gleam"):
    text = path.read_text()
    assert not any(sibling in text for sibling in ("llm_wire", "constellation", "json_blueprint")), path
    if "import gleam/dynamic" in text:
        assert path.name in ("bridge.gleam", "codec.gleam", "telemetry.gleam"), path
for path in (root / "examples").rglob("*.gleam"):
    assert "import http_gun/internal/" not in path.read_text(), path
assert {p.name for p in (root / "src").glob("*.erl")} == {"http_gun_ffi.erl", "http_gun_file_ffi.erl"}
print("Production dependency, Dynamic and public-consumer boundaries passed.")
