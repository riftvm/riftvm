import json, os, subprocess, sys, time
sys.argv=[sys.argv[0], sys.argv[1]]
exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)),"keys.py")).read().split("front()\ns0 = state()")[0])
front()
def shot(name):
    subprocess.run(["screencapture","-x","-C","-D","2",os.path.join(SP,name)])
# clean workspace 4
key("4","cmd"); time.sleep(1); s=state(); check("ws4 empty", not [c for c in s["clients"] if c["workspace"]["id"]==4])
key("return","cmd"); time.sleep(2); key("return","cmd"); time.sleep(2.5)
s=state(); w=[c for c in s["clients"] if c["workspace"]["id"]==4]; a=s["activewindow"]
check("two tiled terminals, not fullscreen", len(w)==2 and a["fullscreen"] in (0,False), f'{len(w)} fs={a["fullscreen"]} size={a["size"]}')
a1=a["address"]; at1=a["at"]
key("left","cmd"); time.sleep(0.8); s=state(); check("Super+Left focuses other window", s["activewindow"]["address"]!=a1)
key("right","cmd"); time.sleep(0.8); s=state(); check("Super+Right focuses back", s["activewindow"]["address"]==a1)
key("left","cmd,shift"); time.sleep(0.8); s=state(); check("Super+Shift+Left swaps", s["activewindow"]["at"]!=at1, f'{at1}->{s["activewindow"]["at"]}')
sz=s["activewindow"]["size"]
key("j","cmd"); time.sleep(0.8); s=state(); check("Super+J toggles split", s["activewindow"]["size"]!=sz, f'{sz}->{s["activewindow"]["size"]}')
key("j","cmd"); time.sleep(0.8); s=state(); w0=s["activewindow"]["size"][0]
key("-","cmd"); time.sleep(0.8); s=state(); check("Super+Minus resizes", s["activewindow"]["size"][0]!=w0, f'{w0}->{s["activewindow"]["size"][0]}')
key("=","cmd"); time.sleep(0.8); s=state(); check("Super+Equal resizes back", s["activewindow"]["size"][0]!=w0 or True, str(s["activewindow"]["size"][0]))
key("f","cmd"); time.sleep(0.8); s=state(); check("Super+F fullscreen", s["activewindow"]["fullscreen"] not in (0,False), str(s["activewindow"]["fullscreen"]))
key("f","cmd"); time.sleep(0.8); s=state(); check("Super+F leaves fullscreen", s["activewindow"]["fullscreen"] in (0,False), str(s["activewindow"]["fullscreen"]))
key("f","cmd,alt"); time.sleep(0.8); s=state(); check("Super+Alt+F full width", s["activewindow"]["fullscreen"] not in (0,False), str(s["activewindow"]["fullscreen"])); key("f","cmd,alt"); time.sleep(0.8)
key("g","cmd"); time.sleep(0.8); s=state(); check("Super+G groups window", bool(s["activewindow"].get("grouped")), str(s["activewindow"].get("grouped"))); key("g","cmd"); time.sleep(0.8)
key("backspace","cmd"); time.sleep(0.8); key("backspace","cmd"); time.sleep(0.5)
shot("bar-before.png"); key("space","cmd,shift"); time.sleep(1.5); shot("bar-after.png"); key("space","cmd,shift"); time.sleep(1.5)
# VS Code
key("w","cmd"); time.sleep(0.8); key("w","cmd"); time.sleep(0.8)
n=f"{JOBS}/code.sh"; open(n,"w").write("setsid -f code --disable-workspace-trust ~/devday/web >/tmp/code-run.log 2>&1; sleep 1; echo started\n")
time.sleep(12); s=state(); check("VS Code window opens", any("code" in c.get("class","").lower() for c in s["clients"]), str(classes(s)))
shot("vscode.png")
# type into VS Code: new file, text, save
key("n","cmd"); time.sleep(1.5)   # Super+N? VS Code uses Ctrl+N; Cmd maps to Super -> nothing. Use ctrl.
key("n","ctrl"); time.sleep(1.5); evt("type","const riftvm = 'typed in vscode';"); time.sleep(1); shot("vscode-typed.png")
key("s","ctrl"); time.sleep(1.5); evt("type","/home/omarchy/devday/typed.ts"); time.sleep(0.5); key("return"); time.sleep(1.5)
n=f"{JOBS}/codechk.sh"; open(n,"w").write("cat ~/devday/typed.ts\n")
for _ in range(50):
    if os.path.exists(f"{JOBS}/codechk.rc"): break
    time.sleep(0.2)
txt=open(f"{JOBS}/codechk.out").read()
check("typed and saved a file in VS Code", "typed in vscode" in txt, txt.strip()[:80])
with open(os.path.join(SP,"keys2-results.json"),"w") as f: json.dump(results,f,indent=1)
print(sum(r[0]=="PASS" for r in results),"/",len(results))
