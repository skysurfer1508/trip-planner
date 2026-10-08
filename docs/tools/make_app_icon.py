import math, zlib, struct, sys, os
N = 1024
OUT = sys.argv[1]

def hexrgb(h): h=h.lstrip('#'); return tuple(int(h[i:i+2],16) for i in (0,2,4))

def bez(p0,p1,p2,p3,t):
    u=1-t
    return (u**3*p0[0]+3*u*u*t*p1[0]+3*u*t*t*p2[0]+t**3*p3[0],
            u**3*p0[1]+3*u*u*t*p1[1]+3*u*t*t*p2[1]+t**3*p3[1])

def render(top, bottom, fg, hole, path):
    hole_at=lambda y: tuple(round(top[i]*(1-y/(N-1))+bottom[i]*(y/(N-1))) for i in range(3))
    # canvas rows of floats per channel stored as bytearray RGB
    rows=[]
    for y in range(N):
        k=y/(N-1)
        c=[round(top[i]*(1-k)+bottom[i]*k) for i in range(3)]
        rows.append(bytearray(c*N))
    def stamp(cx,cy,r,col,mode_max=True):
        x0=max(0,int(cx-r-2)); x1=min(N-1,int(cx+r+2)); y0=max(0,int(cy-r-2)); y1=min(N-1,int(cy+r+2))
        for y in range(y0,y1+1):
            row=rows[y]; dy=y+0.5-cy
            for x in range(x0,x1+1):
                dx=x+0.5-cx; d=math.sqrt(dx*dx+dy*dy)
                cov=r+0.5-d
                if cov<=0: continue
                if cov>1: cov=1
                i=x*3
                for ch in range(3):
                    row[i+ch]=round(row[i+ch]*(1-cov)+col[ch]*cov)
    P=path
    # dashed route: dashes measured along the curve's arc length
    pts=[bez(P['p0'],P['p1'],P['p2'],P['p3'],k/3000) for k in range(3001)]
    cum=[0.0]
    for k in range(1,len(pts)):
        cum.append(cum[-1]+math.hypot(pts[k][0]-pts[k-1][0],pts[k][1]-pts[k-1][1]))
    total=cum[-1]; on=34; off=88; pos=70.0
    k=0
    while pos<total-45:
        end=min(pos+on,total-45)
        while k<len(pts) and cum[k]<pos: k+=1
        j=k
        while j<len(pts) and cum[j]<=end:
            stamp(pts[j][0],pts[j][1],P['w']/2,fg); j+=1
        pos+=on+off
    # start marker: hollow ring
    stamp(*P['p0'],P['start_r'],fg); stamp(*P['p0'],P['start_r']*0.45,hole_at(P['p0'][1]))
    # teardrop pin: head circle tapering to the tip where the route ends
    cx,cy=P['head']; tx,ty=P['p3']; R=P['pin_r']; L=math.hypot(tx-cx,ty-cy)
    for k in range(401):
        f=k/400
        stamp(cx+(tx-cx)*f, cy+(ty-cy)*f, R*(1-f)+9*f, fg)
    stamp(cx,cy,P['hole_r'],hole_at(cy))
    return rows

def png(rows,path):
    raw=b''.join(b'\x00'+bytes(r) for r in rows)
    def chunk(t,d): 
        c=struct.pack('>I',len(d))+t+d
        return c+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)
    data=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',N,N,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(b''.join([raw]),9))+chunk(b'IEND',b'')
    open(path,'wb').write(data)

path=dict(p0=(250,800),p1=(250,610),p2=(560,800),p3=(700,610),head=(700,330),w=46,start_r=42,pin_r=135,hole_r=52)
variants={
 'AppIcon.png':      dict(top=hexrgb('#16917E'),bottom=hexrgb('#0B6558'),fg=hexrgb('#FFFFFF'),hole=None),
 'AppIcon-Dark.png': dict(top=hexrgb('#12201D'),bottom=hexrgb('#0A100E'),fg=hexrgb('#4CC3A8'),hole=None),
 'AppIcon-Tinted.png':dict(top=hexrgb('#000000'),bottom=hexrgb('#000000'),fg=hexrgb('#FFFFFF'),hole=None),
}
for name,v in variants.items():
    hole=v['bottom'] if v['hole'] is None else v['hole']
    # the hole sits near the top-right: use the gradient colour at that row
    k=path['p3'][1]/(N-1); hole=tuple(round(v['top'][i]*(1-k)+v['bottom'][i]*k) for i in range(3))
    rows=render(v['top'],v['bottom'],v['fg'],hole,path)
    png(rows,os.path.join(OUT,name)); print('wrote',name)
