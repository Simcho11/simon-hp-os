"""Passes one request line from stdin to an HP-OS device socket and prints every line it answers."""
import socket
import sys

connection = socket.socket(socket.AF_UNIX)
connection.connect(sys.argv[1])
connection.sendall(sys.stdin.readline().encode())
for line in connection.makefile("r", encoding="utf-8", errors="replace"):
    print(line, end="", flush=True)
