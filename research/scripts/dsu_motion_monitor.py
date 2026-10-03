#!/usr/bin/env python3
"""DSU client that summarizes each connected controller every 2 s: transport, packets per second, how many
carry motion, and mean accel (g) / gyro (°/s) in SDL's frame. Used to check motion over USB and Bluetooth.

    python3 dsu_motion_monitor.py [seconds]      # default 120
"""
import socket,struct,zlib,time,sys
def msg(t,p=b''):
    body=struct.pack('<I',t)+p; q=bytearray(b'DSUC'+struct.pack('<HHII',1001,len(body),0,9)+body); struct.pack_into('<I',q,8,zlib.crc32(bytes(q))&0xffffffff); return bytes(q)
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(0.3); a=('127.0.0.1',26760)
t0=time.time(); last=0; win=[]; state={}
def ts(): return f't+{time.time()-t0:5.1f}s'
while time.time()-t0<float(sys.argv[1] if len(sys.argv) > 1 else 120):
    if time.time()-last>1:
        s.sendto(msg(0x100002,bytes([0,0])+bytes(6)),a); s.sendto(msg(0x100001,struct.pack('<i',4)+bytes([0,1,2,3])),a); last=time.time()
    try: d=s.recv(128)
    except socket.timeout: continue
    t=struct.unpack_from('<I',d,16)[0]; b=d[20:]
    if t==0x100001:
        k=(b[1],b[3],b[2])
        if state.get(b[0])!=k: state[b[0]]=k; print(ts(), f'slot {b[0]}:', 'empty' if b[1]!=2 else f'connected via {"USB" if b[3]==1 else "Bluetooth"}, motion model {b[2]}', flush=True)
    elif t==0x100002 and b[3]==2:
        tsu=struct.unpack_from('<Q',b,48)[0]; ax,ay,az,gp,gy,gr=struct.unpack_from('<6f',b,56)
        win.append((time.time(),tsu,-ax,-ay,-az,gp,-gy,-gr))
        if win[-1][0]-win[0][0]>=2:
            n=len(win); motion=sum(1 for w in win if w[1]); m=[sum(w[i] for w in win)/n for i in range(2,8)]
            print(ts(), f'BT slot {b[0]}: {n/2:.0f} pkts/s, {motion/2:.0f} with motion/s, accel {m[0]:+.2f} {m[1]:+.2f} {m[2]:+.2f} g, gyro {m[3]:+6.1f} {m[4]:+6.1f} {m[5]:+6.1f} °/s', flush=True); win=[]
