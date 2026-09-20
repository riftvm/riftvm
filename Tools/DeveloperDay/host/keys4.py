import json, os, subprocess, sys, time
exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)),"keys3.py")).read().split("front(); key(\"escape\")")[0])
front(); key("escape"); time.sleep(0.5); key("escape"); time.sleep(0.5)
job("openfile","printf 'first line\\n' > ~/devday/edit.ts; code -r ~/devday/edit.ts; sleep 3; hyprctl dispatch focuswindow 'class:^(code)$'\n")
time.sleep(2); front()
key("escape"); time.sleep(0.3)
key("down","ctrl") if False else None
evt("key", 119, "ctrl")  # ctrl+End
evt("type","\nconst riftvm = 'typed in vscode';"); time.sleep(0.5)
key("s","ctrl"); time.sleep(1.5)
subprocess.run(["screencapture","-x","-C","-D","2",os.path.join(SP,"vscode-edit.png")])
out=job("codechk3","cat ~/devday/edit.ts\n")
check("edit and save an existing file in VS Code", "typed in vscode" in out, out.strip().replace("\n"," | ")[:100])
key("a","ctrl"); key("c","cmd"); time.sleep(0.4); evt("key",119,"ctrl"); key("return"); key("v","cmd"); time.sleep(0.8); key("s","ctrl"); time.sleep(1.2)
out=job("codechk4","cat ~/devday/edit.ts\n")
check("Super+C / Super+V copy and paste in VS Code", out.count("typed in vscode")>=2, str(out.count("typed in vscode")))
print(sum(r[0]=="PASS" for r in results),"/",len(results))
