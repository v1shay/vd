"""Live read-only display viewer for Kitty graphics terminals."""
import base64
import contextlib
import fcntl
import json
import os
import secrets
import select
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import time
import tty

ESC = b"\x1b"
END = ESC + b"\\"
PNG = b"\x89PNG\r\n\x1a\n"

def graphic(fields, data=b""):
    return ESC+b"_G"+fields+b";"+data+END

@contextlib.contextmanager
def terminal():
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        raise ValueError("Run vd view in an interactive terminal with Kitty graphics support.")
    fd=sys.stdin.fileno()
    saved=termios.tcgetattr(fd)
    old_handlers={}
    def stop(*_):
        raise KeyboardInterrupt
    try:
        for sig in (signal.SIGTERM,signal.SIGHUP):
            old_handlers[sig]=signal.signal(sig,stop)
        tty.setcbreak(fd)
        token=secrets.randbelow(1000000)+1
        send(graphic(f"a=q,i={token},f=24,s=1,v=1".encode(),b"AAAA"))
        deadline=time.monotonic()+1.5
        answer=b""
        while time.monotonic()<deadline:
            if not select.select([fd],[],[],max(0,deadline-time.monotonic()))[0]:break
            answer+=os.read(fd,1024)
            if f"i={token};OK".encode()+END in answer:break
        if f"i={token};OK".encode()+END not in answer:
            raise ValueError("This terminal did not acknowledge Kitty graphics. Use a compatible terminal with graphics passthrough enabled.")
        send(ESC+b"[?1049h"+ESC+b"[?25l"+ESC+b"[2J")
        try:yield fd
        finally:send(ESC+b"[?25h"+ESC+b"[?1049l")
    finally:
        termios.tcsetattr(fd,termios.TCSANOW,saved)
        for sig,handler in old_handlers.items():signal.signal(sig,handler)

def send(data):
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()

@contextlib.contextmanager
def frames(app, target):
    # Short pathname to fit Darwin sockaddr_un. mkdtemp gives the owning user exclusive access.
    with tempfile.TemporaryDirectory(prefix="vd-view-",dir="/tmp") as folder, socket.socket(socket.AF_UNIX) as listener:
        path=folder+"/frames"
        listener.bind(path);listener.listen(1);listener.settimeout(6)
        subprocess.run(["open","-g","-n",str(app),"--args","viewer-stream",str(target),path],check=True)
        try:conn,_=listener.accept()
        except TimeoutError:raise ValueError("The signed display capture helper did not connect.") from None
        with conn:yield conn

def geometry(fd):
    rows,cols,w,h=struct.unpack("HHHH",fcntl.ioctl(fd,termios.TIOCGWINSZ,b"\0"*8))
    rows,cols=max(rows,2),max(cols,1)
    return rows,cols,w or cols*8,h or rows*16

def paint(image, geom, number, previous):
    rows,cols,w,h=geom
    iw,ih=struct.unpack(">II",image[16:24])
    scale=min(w/iw, h/ih)
    c=max(1,min(cols,round(iw*scale*cols/w)))
    r=max(1,min(rows,round(ih*scale*rows/h)))
    data=base64.b64encode(image)
    out=bytearray()
    for offset in range(0,len(data),4096):
        more=int(offset+4096<len(data))
        prefix=f"a=t,f=100,i={number},q=2," if not offset else ""
        out+=graphic(f"{prefix}m={more}".encode(),data[offset:offset+4096])
    out+=ESC+b"[?2026h"+f"\x1b[{1+(rows-r)//2};{1+(cols-c)//2}H".encode()
    out+=graphic(f"a=p,i={number},p=1,c={c},r={r},C=1,q=2".encode())
    if previous is not None:
        out+=graphic(f"a=d,d=I,i={previous},q=2".encode())
    send(out+ESC+b"[?2026l")

def watch(app,host,args):
    def displays():
        return json.loads(subprocess.check_output([host,"viewer-displays"]))
    choices=displays()
    if args==["--list"]:
        print("\n".join(f'{d["id"]}  {d["name"]}' for d in choices) or "No running virtual displays.")
        return
    if len(args)>1 or (args and not args[0].isdigit()):
        raise ValueError("Usage: vd view [DISPLAY_ID | --list]")
    if not choices:raise ValueError("No running virtual displays. Use vd start to create one.")
    choice=next((d for d in choices if d["id"]==int(args[0])),None) if args else next((d for d in choices if d["vd"]),choices[0])
    if not choice:raise ValueError("Unknown virtual display. Run vd view --list.")
    number=secrets.randbelow(2**30)+1
    with terminal() as fd, contextlib.ExitStack() as cleanup:
        for buffer_id in (number,number+1):
            cleanup.callback(send,graphic(f"a=d,d=I,i={buffer_id},q=2".encode()))
        previous=None
        while True:
            image=None;geom=None;pending=bytearray()
            deadline=time.monotonic()+12
            with frames(app,choice["id"]) as conn:
                while True:
                    ready=select.select([fd,conn],[],[],.2)[0]
                    if fd in ready:
                        keys=os.read(fd,1024)
                        if not keys or b"q" in keys or b"\x1b" in keys:return
                        resized=False
                        for key in keys:
                            if key in b"-_+=0fF" and choice["vd"]:
                                step=1 if key in b"-_" else -1 if key in b"+=" else 0
                                result=subprocess.run([host,"viewer-zoom",str(choice["id"]),str(step)],capture_output=True,text=True)
                                if result.returncode:raise ValueError(result.stdout.strip() or result.stderr.strip())
                                resized |= json.loads(result.stdout)["changed"]
                        if resized:break
                        if b"\t" in keys:
                            choices=displays()
                            if not choices:raise ValueError("All virtual displays disconnected.")
                            idx=next((i for i,d in enumerate(choices) if d["id"]==choice["id"]),-1)
                            choice=choices[(idx+1)%len(choices)]
                            break
                    changed=False
                    if conn in ready:
                        block=conn.recv(262144)
                        if not block:raise ValueError("Virtual display stream ended.")
                        pending.extend(block)
                        while len(pending)>=4:
                            size=struct.unpack_from(">I",pending)[0]
                            if size>128*1024*1024:raise ValueError("Invalid capture packet.")
                            if len(pending)<size+4:break
                            packet=bytes(pending[4:size+4]);del pending[:size+4]
                            if not packet.startswith(PNG):raise ValueError(packet.decode(errors="replace"))
                            changed |= packet!=image
                            image=packet
                    current=geometry(fd)
                    if image and (changed or current!=geom):
                        target=number+1 if previous==number else number
                        paint(image,current,target,previous)
                        previous=target
                        geom=current
                    if image is None and time.monotonic()>deadline:raise ValueError("No display frames received.")
