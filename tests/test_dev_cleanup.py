"""Run with: python3 tests/test_dev_cleanup.py"""

import os
import signal
import socket
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def listening(port):
    with socket.socket() as sock:
        return sock.connect_ex(("127.0.0.1", port)) == 0


def run_case(mode, temp, stop_signal=signal.SIGTERM):
    front_port, back_port = free_port(), free_port()
    while back_port == front_port:
        back_port = free_port()
    expected = {
        "front": [front_port],
        "back": [back_port],
        "all": [front_port, back_port],
    }[mode]
    pid_file = temp / f"{mode}.pids"
    pid_file.write_text("")
    log_file = temp / f"{mode}.log"
    env = os.environ | {
        "PATH": f"{temp / 'bin'}:{os.environ['PATH']}",
        "FRONT_PORT": str(front_port),
        "BACKEND_PORT": str(back_port),
        "DEV_TEST_SERVER": str(temp / "server.py"),
        "DEV_TEST_PIDS": str(pid_file),
    }
    env.pop("ASTRO_DEV_BACKGROUND", None)
    with log_file.open("w") as log:
        proc = subprocess.Popen(
            [str(ROOT / "dev.sh"), mode],
            cwd=ROOT,
            env=env,
            stdout=log,
            stderr=subprocess.STDOUT,
        )
        try:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline and not all(
                listening(port) for port in expected
            ):
                if proc.poll() is not None:
                    break
                time.sleep(0.1)
            assert all(listening(port) for port in expected), log_file.read_text()
            proc.send_signal(stop_signal)
            assert proc.wait(timeout=10) == 128 + stop_signal, log_file.read_text()
            assert not any(listening(port) for port in expected), log_file.read_text()
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
            if pid_file.exists():
                for pid in pid_file.read_text().splitlines():
                    try:
                        os.kill(int(pid), signal.SIGKILL)
                    except ProcessLookupError:
                        pass


def main():
    with tempfile.TemporaryDirectory() as directory:
        temp = Path(directory)
        bin_dir = temp / "bin"
        bin_dir.mkdir()
        stub = bin_dir / "pnpm"
        stub.write_text(
            "#!/usr/bin/env bash\n"
            'if [[ "$1" == install || "$1" == sync || "$2" == python ]]; then exit 0; fi\n'
            'if [[ "$2" == dev && -z "${ASTRO_DEV_BACKGROUND:-}" ]]; then\n'
            "  python3 -c 'import os, subprocess, sys; "
            'p = subprocess.Popen([sys.executable, os.environ["DEV_TEST_SERVER"], '
            "sys.argv[1]], start_new_session=True); "
            'open(os.environ["DEV_TEST_PIDS"], "a").write(str(p.pid) + "\\n")\' '
            '"${@: -1}"\n'
            "  exit 0\n"
            "fi\n"
            'python3 "$DEV_TEST_SERVER" "${@: -1}" &\n'
            'echo "$!" >> "$DEV_TEST_PIDS"\n'
            'wait "$!"\n'
        )
        stub.chmod(0o755)
        (bin_dir / "uv").symlink_to(stub)
        (temp / "server.py").write_text(
            "import signal, socket, sys, time\n"
            "sock = socket.socket()\n"
            "sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)\n"
            'sock.bind(("127.0.0.1", int(sys.argv[1])))\n'
            "sock.listen()\n"
            "def stop(*args):\n"
            "    time.sleep(0.5)\n"
            "    sys.exit(0)\n"
            "signal.signal(signal.SIGTERM, stop)\n"
            "while True:\n"
            "    connection, _ = sock.accept()\n"
            "    connection.close()\n"
        )
        for mode in ("front", "back", "all"):
            run_case(mode, temp)
            print(f"{mode}: child ports released before dev.sh exits")
        run_case("all", temp, signal.SIGINT)
        print("all + Ctrl+C: child ports released before dev.sh exits")
        run_case("all", temp, signal.SIGHUP)
        print("all + terminal close: child ports released before dev.sh exits")


if __name__ == "__main__":
    main()
