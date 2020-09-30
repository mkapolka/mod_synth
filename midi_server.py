import rtmidi
import socketserver
import socket
import os
import time
import errno

def cc_msg(controller, value):
    return "%s %s\n" % (controller, value)

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)

midi_in = rtmidi.RtMidiIn()
midi_in.openPort(0)

cc_values = {}

s.bind(('localhost', 9999))
try:
    while True:
        s.listen(1)
        print("Starting server. Listening on localhost:9999")
        try:
            conn, addr = s.accept()
            for key, value in cc_values.items():
                msg = cc_msg(key, value)
                conn.sendall(bytes(msg, 'ascii'))
            print("Accepted connection. Beginning transmission")
            while True:
                m = midi_in.getMessage(250)
                if m:
                    controller_number = m.getControllerNumber()
                    controller_value = m.getControllerValue()
                    cc_values[controller_number] = controller_value
                    msg = cc_msg(controller_number, controller_value)
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
