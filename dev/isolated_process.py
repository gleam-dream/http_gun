"""Stop the isolated gate and its descendants before workspace cleanup."""

import os
from pathlib import Path
import signal
import subprocess
import time


def signal_group(pid: int, sig: int):
    try:
        os.killpg(pid, sig)
    except ProcessLookupError:
        pass


def group_exists(pid: int) -> bool:
    try:
        os.killpg(pid, 0)
        return True
    except ProcessLookupError:
        return False


def run(
    command: list[str],
    *,
    cwd: Path,
    env: dict[str, str],
    timeout: float,
    grace: float = 5,
) -> int:
    process = subprocess.Popen(command, cwd=cwd, env=env, start_new_session=True)
    try:
        return process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        signal_group(process.pid, signal.SIGTERM)
        deadline = time.monotonic() + grace
        while group_exists(process.pid) and time.monotonic() < deadline:
            process.poll()
            time.sleep(0.02)
        signal_group(process.pid, signal.SIGKILL)
        process.wait()
        raise
