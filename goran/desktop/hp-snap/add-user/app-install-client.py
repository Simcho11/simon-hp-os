"""Passes one request line from stdin to HP-OS's app installer, with the app's file opened here (never its path),
and prints the answer."""
import array
import os
import socket
import sys

connection = socket.socket(socket.AF_UNIX)
connection.connect(sys.argv[1])
line = sys.stdin.readline().encode()
if len(sys.argv) > 2:
    descriptor = os.open(sys.argv[2], os.O_RDONLY | os.O_CLOEXEC)
    connection.sendmsg([line], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [descriptor]))])
    os.close(descriptor)
else:
    connection.sendall(line)
for answer in connection.makefile("r", encoding="utf-8", errors="replace"):
    print(answer, end="", flush=True)
