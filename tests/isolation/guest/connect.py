#!/usr/bin/python3
"""Exits 0 when a connection succeeds. Usage: connect.py abstract|unix|tcp TARGET"""
import socket
import sys

kind, target = sys.argv[1:3]
if kind == "tcp":
    sock, address = socket.socket(socket.AF_INET), ("127.0.0.1", int(target))
else:
    sock = socket.socket(socket.AF_UNIX)
    address = "\0" + target if kind == "abstract" else target
sock.settimeout(5)
try:
    sock.connect(address)
except OSError as error:
    sys.exit(f"connect: {error}")
