#!/usr/bin/python3
"""Exits 0 when a connection succeeds. Usage: connect.py abstract|unix|tcp TARGET

A tcp TARGET is PORT on loopback, or HOST:PORT.
"""
import socket
import sys

kind, target = sys.argv[1:3]
if kind == "tcp":
    host, _, port = target.rpartition(":")
    sock, address = socket.socket(socket.AF_INET), (host or "127.0.0.1", int(port))
else:
    sock = socket.socket(socket.AF_UNIX)
    address = "\0" + target if kind == "abstract" else target
sock.settimeout(5)
try:
    sock.connect(address)
except OSError as error:
    sys.exit(f"connect: {error}")
