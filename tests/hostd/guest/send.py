#!/usr/bin/python3
"""Sends one raw line to hostd and prints the JSON reply."""
import socket
import sys

sock = socket.socket(socket.AF_UNIX)
sock.connect("/run/agentos/hostd.sock")
sock.sendall(sys.argv[1].encode() + b"\n")
sock.shutdown(socket.SHUT_WR)
print(sock.makefile().read())
