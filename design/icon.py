from PIL import Image, ImageDraw, ImageFont, ImageFilter, ImageChops
import sys, math, random
random.seed(7)
S=1024; K=2; W=S*K
font_path, out_full, out_prev = sys.argv[1], sys.argv[2], sys.argv[3]
CX, CY = W*0.5, W*0.47
BLUE=(40,170,255); PURPLE=(200,60,255); PINK=(255,70,220)

def blank(c=0): return Image.new('L',(W,W),c)
def solid(c): return Image.new('RGB',(W,W),c)
def hgrad(a,b):
    g=Image.new('RGB',(W,1))
    for x in range(W):
        t=min(1,max(0,(x-W*0.18)/(W*0.64)))
        g.putpixel((x,0),tuple(int(a[i]+(b[i]-a[i])*t) for i in range(3)))
    return g.resize((W,W))
NEON=hgrad(BLUE,PURPLE)
def paint(img,mask,src): return Image.composite(src if isinstance(src,Image.Image) else solid(src),img,mask)
def glow(img,mask,src,r,s=1.0):
    g=mask.filter(ImageFilter.GaussianBlur(r*K)).point(lambda v:min(255,int(v*s)))
    return paint(img,g,src)
def outline(mask,w): return ImageChops.subtract(mask,mask.filter(ImageFilter.MinFilter(w)))
def scale(m,f):  # scale mask about centre
    return m.transform((W,W),Image.AFFINE,(1/f,0,CX-CX/f,0,1/f,CY-CY/f),resample=Image.BICUBIC)
def shift(m,dx,dy): return ImageChops.offset(m,int(dx),int(dy))

# ---- background: deep violet night, digital rain, glitch streaks
bg=Image.new('RGB',(1,W))
for y in range(W):
    t=y/W; bg.putpixel((0,y),(int(8+14*t),int(4+4*t),int(22+26*t)))
img=bg.resize((W,W))
rain=blank(); rd=ImageDraw.Draw(rain)
for _ in range(170):
    x=random.randint(0,W); y=random.randint(-W//4,W); L=random.randint(W//12,W//3)
    for yy in range(y,y+L,random.choice([10,14,18])*K):
        rd.line([(x,yy),(x,yy+5*K)],fill=random.randint(40,160),width=K*random.choice([1,2]))
rain=rain.filter(ImageFilter.GaussianBlur(0.6*K))
img=paint(img,rain.point(lambda v:min(255,int(v*1.4))),NEON)
streak=blank(); sd=ImageDraw.Draw(streak)
for _ in range(26):
    y=random.randint(int(W*0.1),int(W*0.85)); side=random.choice([0,1])
    w=random.randint(W//40,W//9); x=random.randint(0,W//7) if side==0 else W-random.randint(0,W//7)-w
    for k in range(random.randint(1,3)):
        sd.rectangle([x,y+k*7*K,x+w-random.randint(0,w//2),y+k*7*K+3*K],fill=random.randint(120,230))
img=paint(img,streak,hgrad(BLUE,PINK))
# soft violet bloom behind the reel
bloom=blank(); ImageDraw.Draw(bloom).ellipse([CX-W*0.42,CY-W*0.42,CX+W*0.42,CY+W*0.42],fill=150)
img=glow(img,bloom,hgrad((30,80,200),(140,30,200)),110,0.9)

# ---- the reel
R_OUT=W*0.36
disc=blank(); ImageDraw.Draw(disc).ellipse([CX-R_OUT,CY-R_OUT,CX+R_OUT,CY+R_OUT],fill=255)
holes=blank(); hd=ImageDraw.Draw(holes)
for i in range(6):
    a=math.radians(-90+i*60)
    pts=[]
    for ang,r in [(0,W*0.105),(-0.42,W*0.30),(0.42,W*0.30)]:
        pts.append((CX+math.cos(a+ang)*r, CY+math.sin(a+ang)*r))
    hd.polygon(pts,fill=255)
holes=holes.filter(ImageFilter.GaussianBlur(26*K)).point(lambda v:255 if v>118 else 0)  # rounded corners
holes=ImageChops.multiply(holes,scale(disc,0.93))
hub=blank(); ImageDraw.Draw(hub).ellipse([CX-W*0.115,CY-W*0.115,CX+W*0.115,CY+W*0.115],fill=255)
holes=ImageChops.subtract(holes,hub.filter(ImageFilter.MaxFilter(21)))
body=ImageChops.subtract(disc,holes)

# 3D depth: extruded back layers toward bottom-right
for k in range(22,0,-2):
    t=k/22
    img=paint(img,shift(body,k*K*0.8,k*K*1.0),(int(20+40*(1-t)),int(6+10*(1-t)),int(50+70*(1-t))))
# glassy dark face with radial shading
face=Image.new('RGB',(W,W),(14,10,34))
shade=blank(); ImageDraw.Draw(shade).ellipse([CX-R_OUT*1.1,CY-R_OUT*1.3,CX+R_OUT*0.6,CY+R_OUT*0.4],fill=110)
face=paint(face,shade.filter(ImageFilter.GaussianBlur(90*K)),(48,40,110))
img=paint(img,body,face)
hole_in=ImageChops.multiply(holes,disc)
img=paint(img,hole_in,(6,4,16))
inner=ImageChops.subtract(hole_in,hole_in.filter(ImageFilter.MinFilter(31))).filter(ImageFilter.GaussianBlur(10*K))
img=paint(img,ImageChops.multiply(inner,hole_in).point(lambda v:int(v*0.6)),hgrad((20,60,140),(90,20,140)))
# circuit traces + concentric rings etched into the face
etch=blank(); ed=ImageDraw.Draw(etch)
for r in [0.33,0.30,0.155,0.135]:
    rr=W*r; ed.ellipse([CX-rr,CY-rr,CX+rr,CY+rr],outline=110,width=K*2)
for _ in range(90):
    a=random.uniform(0,2*math.pi); r1=random.uniform(W*0.14,W*0.33); L=random.uniform(W*0.02,W*0.06)
    x,y=CX+math.cos(a)*r1, CY+math.sin(a)*r1
    if random.random()<0.5: ed.line([(x,y),(x+L,y)],fill=140,width=K*2); ed.line([(x+L,y),(x+L,y+L*0.5)],fill=140,width=K*2)
    else: ed.line([(x,y),(x,y+L)],fill=140,width=K*2)
    ed.ellipse([x-3*K,y-3*K,x+3*K,y+3*K],fill=170)
etch=ImageChops.multiply(etch,body)
img=paint(img,etch.point(lambda v:int(v*0.55)),NEON)

# neon rims: outer edge (thick), holes and hub (medium)
rim=outline(disc,25)
rim2=ImageChops.multiply(outline(scale(disc,0.955),9),disc)
hrim=ImageChops.subtract(holes.filter(ImageFilter.MaxFilter(17)),holes)
for m,r,s in [(rim,34,3.0),(rim,12,2.2),(hrim,22,2.6),(hrim,8,1.8),(rim2,10,1.2)]:
    img=glow(img,m,NEON,r,s)
for m in (rim,hrim,rim2):
    img=paint(img,m,NEON)
core=ImageChops.multiply(rim,outline(disc,7))  # white-hot centre line of the outer rim
img=paint(img,core.point(lambda v:int(v*0.8)),(235,220,255))
img=paint(img,ImageChops.subtract(hrim,hrim.filter(ImageFilter.MinFilter(7))).point(lambda v:int(v*0.7)),(235,225,255))

# ---- the R: dark glass letter with neon edges, extruded
WEIGHT=int(sys.argv[4]) if len(sys.argv)>4 else 0
def load(size):
    f=ImageFont.truetype(font_path,size)
    if WEIGHT:
        try: f.set_variation_by_axes([WEIGHT])
        except Exception: pass
    return f
# same cap height for every font: about 21 % of the icon
probe=load(400*K); pb=ImageDraw.Draw(blank()).textbbox((0,0),'R',font=probe)
font=load(int(400*K*(W*0.21)/(pb[3]-pb[1])))
def letter(dx=0,dy=0):
    m=blank(); d=ImageDraw.Draw(m)
    b=d.textbbox((0,0),'R',font=font); w=b[2]-b[0]; h=b[3]-b[1]
    d.text((CX-w/2-b[0]+dx, CY-h/2-b[1]+dy),'R',font=font,fill=255); return m
L=letter()
for k in range(14,0,-2):
    img=paint(img,letter(k*K*0.8,k*K),(int(40+60*(1-k/14)),8,int(80+90*(1-k/14))))
img=paint(img,L,(10,6,26))
lgrad=Image.new('RGB',(1,W))
for y in range(W):
    t=min(1,max(0,(y-(CY-150*K))/(300*K)))
    lgrad.putpixel((0,y),(int(70+40*t),int(40-10*t),int(140+40*t)))
img=paint(img,ImageChops.multiply(L,L.filter(ImageFilter.MinFilter(21))).point(lambda v:int(v*0.25)),lgrad.resize((W,W)))
ledge=outline(L,23)
img=glow(img,ledge,hgrad((90,190,255),PINK),34,3.2)
img=glow(img,ledge,hgrad((90,190,255),PINK),10,2.2)
img=paint(img,ledge,hgrad((120,210,255),PINK))
img=paint(img,ImageChops.subtract(outline(L,17),outline(L,7)).point(lambda v:int(v*0.9)),(250,240,255))

# glossy sweep across the top half of the reel
gloss=blank(); ImageDraw.Draw(gloss).ellipse([CX-R_OUT*1.2,CY-R_OUT*1.5,CX+R_OUT*1.0,CY-R_OUT*0.05],fill=60)
gloss=ImageChops.multiply(gloss.filter(ImageFilter.GaussianBlur(40*K)),disc)
img=paint(img,gloss,(255,255,255))

# ---- floor reflection
top_of_floor=int(CY+R_OUT+W*0.03)
refl=img.crop((0,top_of_floor-(W-top_of_floor),W,top_of_floor)).transpose(Image.FLIP_TOP_BOTTOM)
fade=Image.new('L',(1,refl.height))
for y in range(refl.height): fade.putpixel((0,y),int(110*(1-y/refl.height)**1.6))
fade=fade.resize(refl.size)
refl=refl.filter(ImageFilter.GaussianBlur(6*K))
base=img.crop((0,top_of_floor,W,W))
img.paste(Image.composite(refl,base,fade),(0,top_of_floor))
# floor shimmer dots
dots=blank(); dd=ImageDraw.Draw(dots)
for _ in range(500):
    x=random.gauss(CX,W*0.22); y=random.uniform(top_of_floor,W)
    dd.rectangle([x,y,x+random.randint(2,6)*K,y+K*2],fill=random.randint(60,200))
img=paint(img,dots,NEON)

# vignette
v=blank(); ImageDraw.Draw(v).ellipse([-W*0.15,-W*0.15,W*1.15,W*1.15],fill=255)
v=ImageChops.invert(v.filter(ImageFilter.GaussianBlur(110*K)))
img=paint(img,v.point(lambda x:int(x*0.75)),(0,0,0))

img=img.resize((S,S),Image.LANCZOS)
img.save(out_full)
p=img.resize((380,380),Image.LANCZOS)
m=Image.new('L',(380,380),0); ImageDraw.Draw(m).rounded_rectangle([0,0,379,379],radius=85,fill=255)
o=Image.new('RGB',(420,420),(242,242,247)); o.paste(p,(20,20),m); o.save(out_prev)
