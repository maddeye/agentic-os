#!/usr/bin/python3
"""Speaks RFB through a command's standard streams and checks one pixel of the screen.

Usage: view_client.py R G B COMMAND...
"""
import struct
import subprocess
import sys

expected = bytes(int(value) for value in sys.argv[1:4])
tunnel = subprocess.Popen(sys.argv[4:], stdin=subprocess.PIPE, stdout=subprocess.PIPE)


def receive(count):
	data = tunnel.stdout.read(count)
	if len(data) != count:
		sys.exit(f"the viewer closed the connection after {len(data)} of {count} bytes")
	return data


def send(data):
	tunnel.stdin.write(data)
	tunnel.stdin.flush()


if receive(12)[:3] != b"RFB":
	sys.exit("no RFB banner")
send(b"RFB 003.008\n")
if 1 not in receive(receive(1)[0]):
	sys.exit("the viewer needs an unexpected security type")
send(b"\x01")
if receive(4) != b"\0\0\0\0":
	sys.exit("the viewer refused the connection")
send(b"\x01")
width, height = struct.unpack(">HH", receive(4))
receive(16)
receive(struct.unpack(">I", receive(4))[0])
# 32-bit little-endian pixels with red in byte 2, and raw encoding only.
send(struct.pack(">BxxxBBBBHHHBBBxxx", 0, 32, 24, 0, 1, 255, 255, 255, 16, 8, 0))
send(struct.pack(">BxHi", 2, 1, 0))
send(struct.pack(">BBHHHH", 3, 0, 0, 0, width, height))
while True:
	kind = receive(1)[0]
	if kind == 0:
		break
	if kind == 3:
		receive(struct.unpack(">xxxI", receive(7))[0])
	elif kind != 2:
		sys.exit(f"unexpected message {kind}")
receive(1)
rectangles = struct.unpack(">H", receive(2))[0]
pixel = None
for _ in range(rectangles):
	x, y, w, h, encoding = struct.unpack(">HHHHi", receive(12))
	if encoding != 0:
		sys.exit(f"unexpected encoding {encoding}")
	body = receive(w * h * 4)
	if x <= 20 < x + w and y <= 20 < y + h:
		offset = ((20 - y) * w + (20 - x)) * 4
		pixel = bytes((body[offset + 2], body[offset + 1], body[offset]))
tunnel.kill()
if pixel != expected:
	sys.exit(f"pixel is {list(pixel) if pixel else None}, expected {list(expected)}")
print(f"ok: remote viewer sees {list(pixel)} on a {width}x{height} screen")
