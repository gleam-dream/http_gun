"""Small executable package boundary checks; no sibling checkout is required."""

from pathlib import Path
import tomllib

root = Path(__file__).resolve().parent.parent
config = tomllib.loads((root / "gleam.toml").read_text())
allowed = {
    "gleam_stdlib",
    "gleam_http",
    "gleam_erlang",
    "gleam_otp",
    "gleam_json",
    "gleam_time",
    "gun",
    "cowlib",
    "file_streams",
    "simplifile",
    "sinal",
}
assert set(config["dependencies"]) == allowed
assert config["dependencies"]["sinal"] == {"path": "../sinal"}
assert all(
    isinstance(value, str)
    for name, value in config["dependencies"].items()
    if name != "sinal"
)
lock = tomllib.loads((root / "manifest.toml").read_text())
versions = {p["name"]: p["version"] for p in lock["packages"]}


def version(text):
    return tuple(int(part) for part in text.split("."))


# Patch ranges (docs/DEPENDENCY-UPGRADES.md); the committed lock holds the minimum.
assert config["dependencies"]["gun"] == ">= 2.6.0 and < 2.7.0"
assert config["dependencies"]["cowlib"] == ">= 2.20.0 and < 2.21.0"
assert (2, 6, 0) <= version(versions["gun"]) < (2, 7, 0)
assert (2, 20, 0) <= version(versions["cowlib"]) < (2, 21, 0)
assert versions["file_streams"] == "1.7.0" and versions["simplifile"] == "2.7.0"
# Owner decision: every public timeout is a gleam_time Duration, major-bounded.
assert config["dependencies"]["gleam_time"] == ">= 1.11.0 and < 2.0.0"
for path in (root / "src").rglob("*.gleam"):
    text = path.read_text()
    assert not any(
        sibling in text for sibling in ("llm_wire", "constellation", "json_blueprint")
    ), path
    if "import gleam/dynamic\n" in text or "import gleam/dynamic.{" in text:
        assert path.name in ("bridge.gleam", "telemetry.gleam"), path
    if "import gleam/dynamic/decode" in text:
        assert path.name in ("codec.gleam", "error.gleam", "telemetry.gleam"), path
    # Convention 9: no @internal functions in public modules.
    if "/internal/" not in str(path):
        assert "@internal" not in text, path
        # Convention 10: every public module has a rendered module doc.
        assert text.startswith("////"), f"{path} needs a //// module doc"
for path in (root / "examples").rglob("*.gleam"):
    assert "import http_gun/internal/" not in path.read_text(), path
assert {p.name for p in (root / "src").glob("*.erl")} == {
    "http_gun_ffi.erl",
    "http_gun_event_h.erl",
    "http_gun_file_ffi.erl",
}
print(
    "Production dependency, Dynamic, module-doc and public-consumer boundaries passed."
)
