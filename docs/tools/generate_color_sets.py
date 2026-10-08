import json, os, sys
ROOT = "TripPlanner/Resources/Assets.xcassets"
# name: (light, dark, light-HC, dark-HC)
T = {
 # surfaces & ink
 "Background":      ("#F3F6F5","#0D1513","#FFFFFF","#000000"),
 "Surface":         ("#FFFFFF","#162320","#FFFFFF","#0A100E"),
 "SurfaceRaised":   ("#FFFFFF","#1E2E2A","#FFFFFF","#121C19"),
 "Separator":       ("#D3DDDA","#2A3A36","#7A8A85","#6F837D"),
 "Ink":             ("#12201D","#EAF1EF","#000000","#FFFFFF"),
 "InkSecondary":    ("#55655F","#9DB0AA","#34423D","#C7D5D0"),
 # accent (global accent colour) and text on it
 "AccentColor":     ("#0F7B6C","#4CC3A8","#0A5A4E","#86E0C9"),
 "OnAccent":        ("#FFFFFF","#06201A","#FFFFFF","#00110D"),
 # status
 "Success":         ("#1B7A3E","#6FD48F","#12602D","#9BE5B2"),
 "Warning":         ("#8F4F00","#FFB454","#6E3C00","#FFCB85"),
 "Danger":          ("#B3261E","#FF8F85","#8C1710","#FFB3AB"),
 "Info":            ("#1F5FA8","#8FBBF2","#154A85","#B5D2F6"),
 # days: solid fills carrying a white number (light) / dark number (dark)
 "Day1":("#2B6CB0","#7DB2F0","#1F5290","#A5CBF5"), "Day2":("#C2410C","#F59E6B","#9A3208","#F9BC96"),
 "Day3":("#6D4AC9","#B9A3F5","#5636A8","#D0C1F8"), "Day4":("#B0306F","#F08FBF","#8C2457","#F5B2D3"),
 "Day5":("#8A5A00","#E3B567","#6B4600","#EBCB93"), "Day6":("#0E7490","#67C7DD","#0A5A70","#92D9E9"),
 "Day7":("#A33B3B","#F0A0A0","#802C2C","#F5BDBD"), "Day8":("#52606D","#B5C0CA","#3B4651","#CED6DD"),
 # stop categories: glyph tint on a neutral surface
 "CatSight":("#5F6B1A","#C5D06A","#454F10","#D6DE92"), "CatFood":("#B3341F","#F29C8C","#8E2615","#F6BDB1"),
 "CatCafe":("#7A5230","#D6AE86","#5E3E22","#E2C6A9"), "CatHotel":("#475569","#A9B8CC","#34404F","#C4D0DF"),
 "CatTransport":("#3F4A54","#B5C0CA","#2C353D","#CED6DD"), "CatNightlife":("#6B2D6E","#D9A3DC","#511F54","#E5C0E7"),
 "CatOther":("#6B6358","#B8AFA3","#4F483F","#CFC8BE"),
}
def lum(h):
    h=h.lstrip('#'); r,g,b=[int(h[i:i+2],16)/255 for i in (0,2,4)]
    f=lambda c: c/12.92 if c<=0.03928 else ((c+0.055)/1.055)**2.4
    return 0.2126*f(r)+0.7152*f(g)+0.0722*f(b)
def cr(a,b):
    la,lb=sorted([lum(a),lum(b)],reverse=True); return (la+0.05)/(lb+0.05)
def comp(h):
    h=h.lstrip('#'); return {"alpha":"1.000","red":"0x"+h[0:2].upper(),"green":"0x"+h[2:4].upper(),"blue":"0x"+h[4:6].upper()}
def entry(h, appearances=None):
    e={"color":{"color-space":"srgb","components":comp(h)},"idiom":"universal"}
    if appearances: e["appearances"]=appearances
    return e
DARK={"appearance":"luminosity","value":"dark"}; HC={"appearance":"contrast","value":"high"}
# contrast checks: (token, background token, min)
checks=[("Ink","Background",4.5),("Ink","Surface",4.5),("InkSecondary","Background",4.5),("InkSecondary","Surface",4.5),("InkSecondary","SurfaceRaised",4.5),
        ("AccentColor","Background",4.5),("AccentColor","Surface",4.5),("OnAccent","AccentColor",4.5),
        ("Success","Surface",4.5),("Warning","Surface",4.5),("Danger","Surface",4.5),("Info","Surface",4.5)]
checks+= [("OnAccent",f"Day{i}",4.5) for i in range(1,9)]  # number on day fill
checks+= [(c,"Surface",4.5) for c in T if c.startswith("Cat")]
bad=0
for fg,bg,m in checks:
    for i,mode in enumerate(["light","dark","light-HC","dark-HC"]):
        f=T[fg][i]; b=T[bg][i]
        # day fills: number colour is OnAccent in light (white) and Background-ish dark ink in dark; use OnAccent value for the mode
        if fg=="OnAccent" and bg.startswith("Day"): f=T["OnAccent"][i]; b=T[bg][i]
        r=cr(f,b)
        if r<m: bad+=1; print(f"FAIL {fg}/{bg} {mode}: {r:.2f} (<{m})  {f} on {b}")
print("contrast failures:",bad)
if "--write" in sys.argv:
    for name,(l,d,lh,dh) in T.items():
        folder=f"{ROOT}/{name}.colorset"; os.makedirs(folder,exist_ok=True)
        doc={"colors":[entry(l),entry(d,[DARK]),entry(lh,[HC]),entry(dh,[DARK,HC])],"info":{"author":"xcode","version":1}}
        json.dump(doc,open(f"{folder}/Contents.json","w"),indent=2); open(f"{folder}/Contents.json","a").write("\n")
    print("wrote",len(T),"colour sets")
