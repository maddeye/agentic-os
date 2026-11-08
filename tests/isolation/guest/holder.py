#!/usr/bin/python3
"""Holds the victim project's resources open while the attacker probes them.

Every resource is world-accessible on purpose. File modes then cannot hide it,
so a blocked probe proves that a namespace or mask did the work.
"""
import os
import pathlib
import socket
import subprocess
import threading
import time

os.umask(0)
root = pathlib.Path(os.environ["VICTIM_ROOT"])


def serve(sock):
    sock.listen()
    while True:
        sock.accept()[0].close()


def listen(family, address):
    sock = socket.socket(family)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(address)
    threading.Thread(target=serve, args=(sock,), daemon=True).start()


for path in ["/tmp/beta-world", "/var/tmp/beta-world", "/dev/shm/beta-world"]:
    pathlib.Path(path).write_text("secret\n")
    os.chmod(path, 0o666)
pathlib.Path("/dev/mqueue/beta-q").touch(mode=0o666)
subprocess.run(["ipcmk", "-M", "4096", "-p", "0666"], check=True, stdout=subprocess.DEVNULL)

(root / "home/secret").write_text("secret\n")
os.chmod(root / "home/secret", 0o600)
(root / "workspace/source").write_text("secret\n")
(root / "home/.git-credentials").write_text("https://token@example.invalid\n")
os.chmod(root / "home/.git-credentials", 0o600)

gui_socket = root / "state/gui.sock"
gui_socket.unlink(missing_ok=True)
listen(socket.AF_UNIX, str(gui_socket))
os.chmod(gui_socket, 0o666)
listen(socket.AF_UNIX, "\0beta-sock")
listen(socket.AF_INET, ("127.0.0.1", 45001))

(root / "state/ready").touch()
while True:
    time.sleep(3600)
