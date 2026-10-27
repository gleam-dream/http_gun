"""Compile isolated consumers against the explicitly selected HTTP Gun source."""

from pathlib import Path
import subprocess
import tempfile
import tomllib
import unittest

from check_downstream import closure, inputs, isolate, prepare_dependencies


class SelectedSourceTests(unittest.TestCase):
    def package(self, root, name, dependencies, source):
        root.mkdir(parents=True)
        subprocess.run(["git", "init", "--quiet", str(root)], check=True)
        (root / "src").mkdir()
        (root / "gleam.toml").write_text(
            f'name = "{name}"\nversion = "0.1.0"\n[dependencies]\n{dependencies}\n'
        )
        (root / "src" / f"{name}.gleam").write_text(source)

    def copies(self, workspace, declaration, *, invalid=False):
        selected = workspace / "selected"
        consumer = workspace / "consumer"
        self.package(
            selected,
            "http_gun",
            "",
            "pub fn selected_only() -> Int { 42 }\n"
            if not invalid
            else "pub fn selected_only( {\n",
        )
        self.package(
            consumer,
            "llm_wire",
            f"http_gun = {declaration}",
            "import http_gun\npub fn main() { http_gun.selected_only() }\n",
        )
        nested = consumer / "examples" / "consumer"
        nested.mkdir(parents=True)
        (nested / "gleam.toml").write_text(
            'name = "nested_consumer"\nversion = "0.1.0"\n[dependencies]\n'
            'llm_wire = { path = "../.." }\n'
            f"http_gun = {declaration}\n"
        )
        (nested / "src").mkdir()
        (nested / "src" / "nested_consumer.gleam").write_text(
            "import http_gun\npub fn main() { http_gun.selected_only() }\n"
        )
        roots = closure(selected, consumer)
        before = {name: inputs(root) for name, root in roots.items()}
        copies = isolate(roots, before, workspace / "copies")
        prepare_dependencies(
            (copies["llm_wire"], copies["llm_wire"] / "examples" / "consumer")
        )
        return copies

    def test_hex_git_and_path_consumers_compile_the_selected_source(self):
        for declaration in (
            '">= 0.1.0 and < 0.2.0"',
            '{ git = "https://example.invalid/http_gun.git", ref = "old", path = "package" }',
            '{ path = "../selected" }',
        ):
            with (
                self.subTest(declaration=declaration),
                tempfile.TemporaryDirectory(
                    prefix="http-gun-selected-source-"
                ) as directory,
            ):
                workspace = Path(directory).resolve()
                copies = self.copies(workspace, declaration)
                for project in (
                    copies["llm_wire"],
                    copies["llm_wire"] / "examples" / "consumer",
                ):
                    config = tomllib.loads((project / "gleam.toml").read_text())
                    self.assertEqual(
                        config["dependencies"]["http_gun"],
                        {"path": str(copies["http_gun"])},
                    )
                    subprocess.run(
                        ["gleam", "build", "--warnings-as-errors"],
                        cwd=project,
                        check=True,
                    )
                original = tomllib.loads(
                    (workspace / "consumer" / "gleam.toml").read_text()
                )
                self.assertEqual(
                    original["dependencies"]["http_gun"],
                    tomllib.loads(f"dependency = {declaration}")["dependency"],
                )

    def test_invalid_selected_source_fails_in_the_compiler(self):
        with tempfile.TemporaryDirectory(
            prefix="http-gun-invalid-selected-source-"
        ) as directory:
            copies = self.copies(
                Path(directory).resolve(), '">= 0.1.0 and < 0.2.0"', invalid=True
            )
            config = tomllib.loads((copies["llm_wire"] / "gleam.toml").read_text())
            self.assertEqual(
                config["dependencies"]["http_gun"],
                {"path": str(copies["http_gun"])},
            )
            result = subprocess.run(
                ["gleam", "build", "--warnings-as-errors"],
                cwd=copies["llm_wire"],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("Syntax error", result.stdout)
            self.assertIn("http_gun.gleam", result.stdout)


if __name__ == "__main__":
    unittest.main()
