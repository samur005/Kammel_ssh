from PIL import Image, ImageDraw, ImageFont
import sys
RAJ='/usr/share/fonts/truetype/sand-box/google/Rajdhani/Rajdhani-Bold.ttf'
MONO='/usr/share/fonts/truetype/sand-box/google/JetBrains Mono/JetBrainsMono-VariableFont_wght.ttf'
BG=(26,32,53,255); FG=(236,239,244,255); FG2=(200,206,216,255); ACC=(255,82,82,255)

def mono(sz):
    f=ImageFont.truetype(MONO,sz)
    try: f.set_variation_by_name('Bold')
    except Exception: pass
    return f

def glyphs(S, mono_color=None, fg=FG, fg2=FG2, acc=ACC):
    """Draw the ABS+ssh mark centered on a transparent SxS canvas, content ~62% wide."""
    im=Image.new('RGBA',(S,S),(0,0,0,0)); d=ImageDraw.Draw(im)
    if mono_color: fg=fg2=acc=mono_color
    u=S/1000
    fA=ImageFont.truetype(RAJ,int(560*u)); fB=ImageFont.truetype(RAJ,int(330*u)); fs=mono(int(118*u))
    base=int(700*u)  # common baseline
    def text_at(x,txt,font,col):
        l,t,r,b=d.textbbox((0,0),txt,font=font,anchor='ls')
        d.text((x,base),txt,font=font,fill=col,anchor='ls'); return x+(r-l)
    # measure total width
    wA=d.textbbox((0,0),'A',font=fA,anchor='ls'); wB=d.textbbox((0,0),'B',font=fB,anchor='ls'); wS=d.textbbox((0,0),'S',font=fB,anchor='ls')
    gap=int(14*u)
    total=(wA[2]-wA[0])+gap+(wB[2]-wB[0])+gap+(wS[2]-wS[0])
    x0=(S-total)/2 - wA[0]
    xB=text_at(x0,'A',fA,fg)+gap
    xS=text_at(xB-wB[0],'B',fB,fg2)+gap
    xEnd=text_at(xS-wS[0],'S',fB,fg2)
    hB=-(wB[1])  # cap height of B
    top_small=base-hB
    # signal bars above S (3 rising bars)
    bw=int(30*u); bg=int(16*u); bx=xEnd-3*bw-2*bg
    for i,h in enumerate((55,95,135)):
        h=int(h*u); x=bx+i*(bw+bg)
        d.rounded_rectangle([x,top_small-int(22*u)-h,x+bw,top_small-int(22*u)],radius=int(6*u),fill=fg2)
    # 'ssh' in the gap above B, between A and bars (where the red arrow was)
    tb=d.textbbox((0,0),'ssh',font=fs,anchor='ls')
    cx=(xB+bx-int(10*u))/2
    d.text((cx-(tb[2]-tb[0])/2-tb[0], top_small-int(40*u)),'ssh',font=fs,fill=acc,anchor='ls')
    return im

def full(S, rounded=False):
    big=S*2
    bgim=Image.new('RGBA',(big,big),(0,0,0,0)); d=ImageDraw.Draw(bgim)
    if rounded: d.rounded_rectangle([0,0,big-1,big-1],radius=int(big*0.22),fill=BG)
    else: d.rectangle([0,0,big,big],fill=BG)
    g=glyphs(big)
    # scale mark slightly bigger for full (non-adaptive) icons
    g=g.resize((int(big*1.12),)*2,Image.LANCZOS); o=(big-g.size[0])//2
    bgim.alpha_composite(g,(o,o))
    return bgim.resize((S,S),Image.LANCZOS)

def adaptive_fg(S):
    big=S*2; g=glyphs(big)
    # adaptive safe zone = inner 66%: shrink mark to fit
    g2=g.resize((int(big*0.80),)*2,Image.LANCZOS); im=Image.new('RGBA',(big,big),(0,0,0,0))
    o=(big-g2.size[0])//2; im.alpha_composite(g2,(o,o)); return im.resize((S,S),Image.LANCZOS)

def white(S, scale=1.25):
    big=S*4; g=glyphs(big,mono_color=(255,255,255,255))
    g=g.resize((int(big*scale),)*2,Image.LANCZOS); im=Image.new('RGBA',(big,big),(0,0,0,0))
    o=(big-g.size[0])//2; im.alpha_composite(g,(o,o)); return im.resize((S,S),Image.LANCZOS)
