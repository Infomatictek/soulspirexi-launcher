"""Run the Ashita addon unit tests with LuaJIT 2.1 via Lupa."""

from pathlib import Path
import os

from lupa.luajit21 import LuaRuntime


def main() -> int:
    repo_root = Path(__file__).resolve().parents[1]
    suites = [
        (repo_root / "addons/ashita4/crystalsocket", "*_test.lua"),
        (repo_root / "addons/ashita4/soulspire_soul_actions", "*_test.lua"),
        (repo_root / "addons/ashita4/soulspire_flintlock", "*_spec.lua"),
    ]
    failures = []
    for addon, pattern in suites:
        os.chdir(addon)
        for path in sorted(Path("tests").glob(pattern)):
            label = f"{addon.name}/{path.name}"
            try:
                LuaRuntime().execute(f"dofile({str(path)!r})")
                print(f"PASS {label}")
            except Exception as error:
                failures.append(label)
                print(f"FAIL {label}: {error}")
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
