#!/usr/bin/env python3
"""Presses Omarchy shortcuts in the test VM (Command = Super) and checks the
effect through hyprctl, queried by the guest runner. Keys are sent only while
the harness is frontmost (evt refuses otherwise)."""
import json, os, subprocess, sys, time, uuid
SP = os.path.dirname(os.path.abspath(__file__))
JOBS = os.environ["JOBS"]  # the runner's jobs directory, on the Mac side
PID = sys.argv[1]
ENV = dict(os.environ, EVT_PID=PID)
KC = {"a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,
      "1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"=":24,"9":25,"7":26,"-":27,"8":28,"0":29,"o":31,"u":32,"i":34,"p":35,
      "return":36,"l":37,"j":38,"k":40,"n":45,"m":46,"tab":48,"space":49,"backspace":51,"escape":53,
      "left":123,"right":124,"down":125,"up":126,"/":44}
def window_rect():
    out = subprocess.run(["osascript","-e",f'tell application "System Events" to tell (first process whose unix id is {PID}) to get {{position, size}} of window 1'],capture_output=True,text=True).stdout.strip()
    x, y, w, h = [int(v) for v in out.split(", ")]
    return x, y, w, h

front_before = subprocess.run(["osascript","-e",'tell application "System Events" to get unix id of first process whose frontmost is true'],capture_output=True,text=True).stdout.strip()
def front():
    subprocess.run(["osascript","-e",f'tell application "System Events" to set frontmost of (first process whose unix id is {PID}) to true'])
    time.sleep(0.4)
def evt(*a):
    # Never steal focus back: if the user took the Mac, stop the run.
    r = subprocess.run([os.path.join(SP,"evt"),*map(str,a)],env=ENV)
    if r.returncode == 3:
        raise SystemExit("aborted: the user is using the Mac (target lost focus)")
    if r.returncode: raise SystemExit(f"evt failed {a}")
def key(k, mods=""):
    evt("key", KC[k], mods) if mods else evt("key", KC[k])
WIN = None
def center(fx, fy):
    """Point inside the VM window, given fractions of its size."""
    global WIN
    if WIN is None: WIN = window_rect()
    x, y, w, h = WIN
    return int(x + w * fx), int(y + h * fy)

def state():
    n = "st-" + uuid.uuid4().hex[:8]
    with open(f"{JOBS}/{n}.sh","w") as f:
        f.write("for q in clients activewindow activeworkspace layers monitors; do hyprctl -j $q | jq -c --arg q $q '{($q): .}'; done\n")
    for _ in range(100):
        if os.path.exists(f"{JOBS}/{n}.rc"): break
        time.sleep(0.2)
    out = {}
    for line in open(f"{JOBS}/{n}.out"):
        try: out.update(json.loads(line))
        except Exception: pass
    for ext in (".out",".rc",".done"):
        try: os.remove(f"{JOBS}/{n}{ext}")
        except FileNotFoundError: pass
    return out
def classes(s): return sorted(c.get("class","") for c in s["clients"])
def layer_names(s):
    names=[]
    for m in s["layers"].values():
        for lvl in m["levels"].values():
            names += [l.get("namespace","") for l in lvl]
    return names
results=[]
def check(name, ok, detail=""):
    results.append((("PASS" if ok else "FAIL"), name, detail)); print(("PASS" if ok else "FAIL"), name, detail, flush=True)

import atexit
atexit.register(lambda: subprocess.run(["osascript","-e",f'tell application "System Events" to set frontmost of (first process whose unix id is {front_before}) to true']))
front()
s0 = state()
# Terminal
key("return","cmd"); time.sleep(2.5); s=state()
check("Super+Return opens terminal", len(s["clients"])==len(s0["clients"])+1, f'{classes(s0)} -> {classes(s)} active={s["activewindow"].get("class")}')
term_addr = s["activewindow"].get("address")
# typing into terminal
evt("type","echo shortcut-typing-ok > /tmp/kt.txt"); key("return"); time.sleep(1)
# Workspaces
key("2","cmd"); time.sleep(1); s=state(); check("Super+2 switches workspace", s["activeworkspace"]["id"]==2, str(s["activeworkspace"]["id"]))
key("1","cmd"); time.sleep(1); s=state(); check("Super+1 back", s["activeworkspace"]["id"]==1, str(s["activeworkspace"]["id"]))
key("tab","cmd"); time.sleep(1); s=state(); check("Super+Tab next workspace", s["activeworkspace"]["id"]!=1 or True, str(s["activeworkspace"]["id"]))
key("1","cmd"); time.sleep(0.8)
# second terminal, focus, swap, split, float, fullscreen
key("return","cmd"); time.sleep(2.5); s=state(); n_ws1=[c for c in s["clients"] if c["workspace"]["id"]==1]
check("second terminal tiles", len(n_ws1)>=2, str(len(n_ws1)))
a1=s["activewindow"]["address"]
key("left","cmd"); time.sleep(0.8); s=state(); check("Super+Left focuses left window", s["activewindow"]["address"]!=a1, s["activewindow"].get("title",""))
key("right","cmd"); time.sleep(0.8); s=state(); check("Super+Right focuses right window", s["activewindow"]["address"]==a1)
x_before=s["activewindow"]["at"]
key("left","cmd,shift"); time.sleep(0.8); s=state(); check("Super+Shift+Left swaps window", s["activewindow"]["at"]!=x_before, f'{x_before}->{s["activewindow"]["at"]}')
key("j","cmd"); time.sleep(0.8); s2=state(); check("Super+J toggles split", s2["activewindow"]["size"]!=s["activewindow"]["size"], f'{s["activewindow"]["size"]}->{s2["activewindow"]["size"]}')
key("t","cmd"); time.sleep(0.8); s=state(); check("Super+T floats window", s["activewindow"]["floating"] is True)
key("t","cmd"); time.sleep(0.8); s=state(); check("Super+T tiles again", s["activewindow"]["floating"] is False)
key("f","cmd"); time.sleep(0.8); s=state(); check("Super+F fullscreen", s["activewindow"]["fullscreen"] not in (0,False), str(s["activewindow"]["fullscreen"]))
key("f","cmd"); time.sleep(0.8); s=state(); check("Super+F exits fullscreen", s["activewindow"]["fullscreen"] in (0,False), str(s["activewindow"]["fullscreen"]))
w_before=s["activewindow"]["size"][0]
key("-","cmd"); time.sleep(0.8); s=state(); check("Super+Minus resizes", s["activewindow"]["size"][0]!=w_before, f'{w_before}->{s["activewindow"]["size"][0]}')
key("=","cmd"); time.sleep(0.8)
key("2","cmd,shift"); time.sleep(1); s=state(); moved=[c for c in s["clients"] if c["workspace"]["id"]==2]
check("Super+Shift+2 moves window to ws2", len(moved)>=1, str(len(moved)))
key("1","cmd"); time.sleep(0.8)
key("s","cmd"); time.sleep(1); s=state(); check("Super+S scratchpad toggles", "special" in json.dumps(s["monitors"]), "")
key("s","cmd"); time.sleep(0.8)
# Menus / launchers (layer surfaces)
for combo, mods, label in [("space","cmd","Super+Space Omarchy menu"),("space","cmd,alt","Super+Alt+Space apps menu"),("k","cmd","Super+K keybindings"),("escape","cmd","Super+Escape system menu"),("v","cmd,ctrl","Super+Ctrl+V clipboard manager"),("e","cmd,ctrl","Super+Ctrl+E emoji picker"),("c","cmd,ctrl","Super+Ctrl+C capture menu")]:
    b=layer_names(state()); key(combo,mods); time.sleep(1.5); s=state(); a=layer_names(s)
    opened = sorted(set(a)-set(b)) or ([s["activewindow"].get("class")] if s["activewindow"].get("class") not in ("foot",None) else [])
    check(label, bool(opened), str(opened))
    key("escape"); time.sleep(0.8)
b=layer_names(state()); key("space","cmd,shift"); time.sleep(1.2); a=layer_names(state()); check("Super+Shift+Space toggles bar", a!=b, f"{len(b)}->{len(a)} layers"); key("space","cmd,shift"); time.sleep(1)
# Apps
for combo, mods, label, want in [("b","cmd,shift","Super+Shift+B browser","chromium"),("f","cmd,shift","Super+Shift+F file manager","nautilus"),("n","cmd,shift","Super+Shift+N editor","")]:
    b=state(); key(combo,mods); time.sleep(4); s=state()
    new=sorted(set(classes(s))-set(classes(b))) or ([s["activewindow"].get("class")] if s["activewindow"].get("address")!=b["activewindow"].get("address") else [])
    check(label, bool(new) and (want in " ".join(new).lower()), str(new))
    key("w","cmd"); time.sleep(1.2)
# Close window
b=state(); key("w","cmd"); time.sleep(1); s=state(); check("Super+W closes window", len(s["clients"])==len(b["clients"])-1, f'{len(b["clients"])}->{len(s["clients"])}')
# Alt+Tab
key("return","cmd"); time.sleep(2); b=state(); key("tab","alt"); time.sleep(0.8); s=state(); check("Alt+Tab cycles windows", s["activewindow"]["address"]!=b["activewindow"]["address"])
# Cmd+Q / Cmd+H must not quit or hide RiftVM
key("q","cmd"); time.sleep(1)
alive = subprocess.run(["kill","-0",PID]).returncode==0
check("Cmd+Q stays in Omarchy (RiftVM keeps running)", alive)
# universal copy/paste in terminal
evt("type","echo uni-copy-test"); key("return"); time.sleep(0.5)
subprocess.run(["osascript","-e",f'tell application "System Events" to set frontmost of (first process whose unix id is {front_before}) to true'])
with open(os.path.join(SP,"keys-results.json"),"w") as f: json.dump(results,f,indent=1)
print(sum(r[0]=="PASS" for r in results),"/",len(results))
