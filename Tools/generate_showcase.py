"""Render privacy-safe, explicitly illustrative GitHub media with Pillow.

Run with Python 3 and Pillow installed. No desktop capture or personal data.
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
import math

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs' / 'images'
OUT.mkdir(parents=True, exist_ok=True)
FONT = '/System/Library/Fonts/STHeiti Medium.ttc'
W, H = 1280, 720
INK = '#edf3ff'
MUTED = '#a6b5cc'
ACCENT = '#86e4c4'

def text(im, xy, s, size=24, fill=INK):
    ImageDraw.Draw(im).text(xy, s, font=ImageFont.truetype(FONT, size), fill=fill)

def box(im, rect, fill, radius=20, outline=None):
    ImageDraw.Draw(im).rounded_rectangle(rect, radius, fill=fill, outline=outline, width=2)

def base(kicker, title, subtitle):
    im = Image.new('RGB', (W, H), '#101b2d')
    d = ImageDraw.Draw(im)
    for y in range(H):
        d.line((0,y,W,y), fill=(16+int(y/90),27+int(y/70),45+int(y/50)))
    text(im,(56,34),kicker,18,ACCENT)
    text(im,(56,73),title,44)
    text(im,(58,136),subtitle,22,MUTED)
    text(im,(56,678),'EdgeHider  /  macOS 13+  /  MIT',16,MUTED)
    text(im,(884,678),'功能示意 · 虚构内容 · 非实机录屏',16,MUTED)
    return im

icon = Image.open(ROOT/'AppIcon.png').convert('RGB')
def brand(im, x, y, size=62):
    thumb=icon.resize((size,size),Image.Resampling.LANCZOS)
    mask=Image.new('L',(size,size)); ImageDraw.Draw(mask).rounded_rectangle((0,0,size,size),size//5,fill=255)
    im.paste(thumb,(x,y),mask)

def desktop(im, rect):
    x,y,r,b=rect
    box(im,rect,'#263d59',18,'#476181')
    d=ImageDraw.Draw(im)
    d.rectangle((x+2,y+25,r-2,b-18),fill='#2d5266')
    d.polygon([(x+2,b-18),(x+2,y+190),(x+190,y+100),(r-2,b-18)],fill='#346e7a')
    d.polygon([(x+140,b-18),(r-2,y+85),(r-2,b-18)],fill='#427f83')
    text(im,(x+17,y+5),'●   示例桌面',13)
    text(im,(r-123,y+5),'EdgeHider',13)
    box(im,(x+145,b-42,r-145,b-8),'#506f80',10)

def window(im,x,y,w=270,h=225):
    box(im,(x+5,y+8,x+w+5,y+h+8),'#203b4d',14)
    box(im,(x,y,x+w,y+h),'#f3f6fc',14)
    d=ImageDraw.Draw(im)
    for i,c in enumerate(('#fa7774','#e9c169','#78cfa1')):
        d.ellipse((x+13+i*16,y+14,x+22+i*16,y+23),fill=c)
    text(im,(x+78,y+11),'示例便笺',15,'#354861')
    text(im,(x+20,y+58),'给桌面留一点空间',20,'#24394f')
    for i,s in enumerate(('整理灵感与待办','让常用窗口随叫随到','专注眼前的工作')):
        box(im,(x+20,y+104+i*31,x+27,y+111+i*31),'#49a78d',3)
        text(im,(x+40,y+99+i*31),s,15,'#60758a')

def cursor(im,x,y):
    ImageDraw.Draw(im).polygon([(x,y),(x+4,y+27),(x+11,y+20),(x+18,y+31),(x+24,y+27),(x+17,y+16),(x+27,y+15)],fill='white',outline='#102033',width=2)

# Cover and share card use the existing application icon.
im=base('WINDOWS, WITH ROOM TO BREATHE','EdgeHider','窗口靠边收起，需要时轻轻唤回。')
brand(im,62,219,110)
text(im,(62,354),'少一点遮挡',36)
text(im,(62,406),'多一点专注',36,ACCENT)
text(im,(62,479),'边缘隐藏  /  悬停唤回',22,MUTED)
text(im,(62,517),'多屏支持  /  自选动画',22,MUTED)
desktop(im,(490,211,1222,610))
window(im,845,295,290,240)
box(im,(1190,373,1218,447),'#dcebf0',8)
text(im,(1196,396),'E',18,'#234356')
im.save(OUT/'cover.png',optimize=True)
im.resize((1280,640),Image.Resampling.LANCZOS).save(OUT/'social-preview.png',optimize=True)

im=base('A SMALL GESTURE. A QUIETER DESKTOP.','从收起到唤回，只需靠近边缘','示例便笺展示操作流程；实际样式与速度取决于应用及动画设置。')
for i,(title,desc) in enumerate((('01  靠边隐藏','把已勾选应用的窗口拖到边缘'),('02  悬停唤回','鼠标靠近边缘标签，窗口滑出'),('03  移开收起','操作结束后移开鼠标，延时隐藏'))):
    x=56+i*397
    box(im,(x,207,x+374,627),'#1d3048',20)
    text(im,(x+22,231),title,24,ACCENT)
    desktop(im,(x+20,284,x+354,503))
    # Clip sample windows at screen edge, just like offscreen movement.
    layer=im.crop((x+22,311,x+352,483))
    window(layer,322 if i!=1 else 105,16,210,148)
    im.paste(layer,(x+22,311))
    cursor(im,x+(321 if i==1 else 70),404)
    text(im,(x+22,539),desc,18,MUTED)
im.save(OUT/'workflow.png',optimize=True)

im=base('MADE FOR YOUR OWN WORKFLOW','每个应用，都可以有自己的节奏','按应用启用 · 四边方向 · 八种动画 · 配置导入与导出')
features=[('01','自由选择应用','只为你勾选的应用启用边缘隐藏。'),('02','多显示器支持','按窗口所在屏幕检测边缘与热区。'),('03','动画与延时','选择动画效果，调整隐藏等待时间。'),('04','锁屏恢复','解锁后恢复窗口管理，已实机验证。')]
for i,(n,title,desc) in enumerate(features):
    x=56+(i%2)*594; y=210+(i//2)*216
    box(im,(x,y,x+574,y+190),'#1d3048',20)
    text(im,(x+26,y+22),n,18,ACCENT)
    text(im,(x+26,y+62),title,28)
    text(im,(x+26,y+116),desc,21,MUTED)
im.save(OUT/'features.png',optimize=True)

frames=[]
# 8-second loop, 12.5fps; screen crop ensures window never draws outside display.
for f in range(100):
    t=f/12.5
    if t<1: phase=0; p=0
    elif t<2: phase=0; p=(t-1)
    elif t<3: phase=1; p=1
    elif t<4: phase=1; p=1-(t-3)
    elif t<5.6: phase=2; p=0
    elif t<6.6: phase=3; p=t-5.6
    else: phase=3; p=1
    p=max(0,min(1,p)); p=p*p*(3-2*p)
    labels=['01  将窗口拖向边缘','02  靠近标签，窗口唤回','03  在窗口中继续操作','04  鼠标移开，延时收起']
    im=base('EDGEHIDER / INTERACTION DEMO','靠边收起，悬停即回',labels[phase])
    desktop(im,(56,194,1224,644))
    layer=im.crop((58,221,1222,600))
    wx=int(720+420*p)
    window(layer,wx,55,310,264)
    if p>.65:
        box(layer,(1138,139,1163,213),'#e1eff2',7)
        text(layer,(1143,164),'E',17,'#234356')
    if phase==1: cx=1140; cy=179
    elif phase==2: cx=895; cy=210
    elif phase==0: cx=min(wx+165,1140); cy=70
    else: cx=565; cy=288
    cursor(layer,cx,cy)
    im.paste(layer,(58,221))
    # Downsample only the animation to keep GitHub loading light.
    frames.append(im.resize((960,540),Image.Resampling.LANCZOS))
frames[0].save(OUT/'edge-hide-demo.gif',save_all=True,append_images=frames[1:],duration=80,loop=0,optimize=True)
frames[45].save(OUT/'demo-poster.png',optimize=True)
print('\n'.join(f'{p.name}: {p.stat().st_size:,} bytes' for p in OUT.iterdir()))
