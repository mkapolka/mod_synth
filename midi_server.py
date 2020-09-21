import rtmidi
import socketserver
import socket
import os
import time
import errno

# SOCKET_FILE = "./sock-it-to-me"

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
# try:
    # os.remove(SOCKET_FILE)
# except Exception as e:
    # pass

midi_in = rtmidi.RtMidiIn()
midi_in.openPort(0)

# s.bind(SOCKET_FILE)
s.bind(('localhost', 9999))
try:
    while True:
        s.listen(1)
        print("Starting server. Listening on localhost:9999")
        try:
            conn, addr = s.accept()
            print("Accepted connection. Beginning transmission")
            while True:
                m = midi_in.getMessage(250)
                if m:
                    msg = "%s %s\n" % (m.getControllerNumber(), m.getControllerValue())
                    conn.sendall(bytes(msg, 'ascii'))
        except KeyboardInterrupt:
            print("Closing connection")
            conn.close()
            raise
        except socket.error as e:
            print("Other side hung up. Closing connection")
            conn.close()
except KeyboardInterrupt:
    print("Closing socket")
    s.close()
