#!/usr/bin/env python3
"""Minimal DSU (CemuHook) client: logs which slots are connected and every change of buttons,
sticks at their edge and analog L2/R2, as NS2 Bridge's DSU server sends them.

    python3 dsu_monitor.py [seconds]      # default 120; times are printed relative to start
"""
import socket, struct, zlib, time, sys
START=time.time()
def ts(): return f"t+{time.time()-START:6.1f}s"
def msg(t, payload=b''):
    body=struct.pack('<I',t)+payload
    p=bytearray(b'DSUC'+struct.pack('<HHII',1001,len(body),0,7)+body)
    struct.pack_into('<I',p,8,zlib.crc32(bytes(p))&0xffffffff); return bytes(p)
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(0.2); a=('127.0.0.1',26760)
end=time.time()+float(sys.argv[1] if len(sys.argv)>1 else 120); last_req=0; ports={}; prev={}; counts={}
B1=['share','L3','R3','options','up','right','down','left']; B2=['L2','R2','L1','R1','north','east','south','west']
while time.time()<end:
    if time.time()-last_req>1:
        s.sendto(msg(0x100002, bytes([0,0])+bytes(6)),a); s.sendto(msg(0x100001, struct.pack('<i',4)+bytes([0,1,2,3])),a); last_req=time.time()
    try: d=s.recv(128)
    except socket.timeout: continue
    t=struct.unpack_from('<I',d,16)[0]; b=d[20:]
    slot,state,conn=b[0],b[1],b[3]
    if t==0x100001:
        key=(state,conn)
        if ports.get(slot)!=key:
            ports[slot]=key; print(f'{ts()} slot {slot}: {"connected" if state==2 else "empty"}{" via "+("USB" if conn==1 else "Bluetooth") if state==2 else ""}', flush=True)
    elif t==0x100002:
        counts[slot]=counts.get(slot,0)+1
        pressed=[n for i,n in enumerate(B1) if b[16]>>i&1]+[n for i,n in enumerate(B2) if b[17]>>i&1]+(['home'] if b[18] else [])+(['touch'] if b[19] else [])
        sticks=tuple(b[20:24]); trig=(b[35],b[34])
        big=[i for i,v in enumerate(sticks) if abs(v-128)>100]
        state=(tuple(pressed),tuple(big),tuple(1 if v>200 else 0 for v in trig))
        if prev.get(slot)!=state:
            prev[slot]=state; print(f'{ts()} slot {slot}{" BT" if conn==2 else ""}: buttons {pressed} sticks-at-edge {["LX","LY","RX","RY"][0:0]+[["LX","LY","RX","RY"][i]+("+" if sticks[i]>128 else "-") for i in big]} L2/R2 analog {trig}', flush=True)
for k,v in counts.items(): print(f'slot {k}: {v} packets', flush=True)
