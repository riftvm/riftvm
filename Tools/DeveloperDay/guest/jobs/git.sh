source "$(dirname "$0")/../lib.sh"
export GIT_TERMINAL_PROMPT=0
w=~/devday; rm -rf $w; mkdir -p $w && cd $w
step "image: make/patch present (base-devel)" bash -c 'make --version | head -1 && patch --version | head -1 && pacman -Qg base-devel | wc -l'
step "git config" bash -c 'git config --global user.name "Dev Tester" && git config --global user.email dev@example.com && git config --global init.defaultBranch main && git config --global pull.rebase false'
step "git init+commit" bash -c 'git init -q repo && cd repo && printf "# Demo\n" > README.md && git add . && git commit -qm "init"'
cd repo
step "branch+merge --no-ff" bash -c 'git switch -qc feature && echo "feature line" >> README.md && git commit -qam feature && git switch -q main && git merge -q --no-ff feature -m "merge feature" && grep -q "feature line" README.md'
step "merge conflict + resolve" bash -c 'git switch -qc a && echo A > f.txt && git add f.txt && git commit -qm a && git switch -q main && git switch -qc b && echo B > f.txt && git add f.txt && git commit -qm b && git switch -q main && git merge -q a && ! git merge -q b 2>/dev/null && echo AB > f.txt && git add f.txt && git commit -qm resolve && git status --porcelain | wc -l | grep -qx 0'
step "rebase" bash -c 'git switch -qc topic main~1 && echo t > t.txt && git add t.txt && git commit -qm topic && git rebase -q main && git log --oneline -1 | grep -q topic && git switch -q main'
step "stash/pop" bash -c 'echo dirty >> README.md && git stash -q && git diff --quiet && git stash pop -q && ! git diff --quiet && git checkout -q README.md'
step "tag+describe" bash -c 'git tag -a v0.1.0 -m v0.1.0 && git describe --tags | grep -q v0.1.0'
step "bisect run" bash -c 'echo 0 > n.txt && git add n.txt && git commit -qm n0 && good=$(git rev-parse HEAD); for i in 1 2 3 4 5; do echo $i > n.txt; git add n.txt; git commit -qm "n$i"; done; git bisect start HEAD "$good" >/dev/null 2>&1; git bisect run sh -c "[ \$(cat n.txt) -lt 4 ]" >/tmp/bisect.log 2>&1; git bisect reset >/dev/null 2>&1; grep -q "is the first .bad. commit" /tmp/bisect.log'
step "worktree" bash -c 'git worktree add -q ../wt -b wt && test -f ../wt/README.md && git worktree remove ../wt'
step "diff/patch round trip" bash -c 'cp README.md /tmp/r0 && echo add >> README.md && git diff > /tmp/p.diff && git checkout -q README.md && patch -s -p1 < /tmp/p.diff && grep -q add README.md && git checkout -q README.md'
cd $w
step "clone https (github)" git clone -q --depth 20 https://github.com/octocat/Hello-World.git hello
step "clone vite (blobless)" git clone -q --filter=blob:none --depth 1 https://github.com/vitejs/vite.git vite
step "gh cli" gh --version
step "nvim headless edit" bash -c 'printf "hello\nworld\n" > e.txt && nvim --headless -c "%s/world/omarchy/" -c "wq" e.txt && grep -qx omarchy e.txt'
step "rg/fd/fzf/jq" bash -c 'rg -q omarchy e.txt && fd -q e.txt . && echo e.txt | fzf -f e.txt | grep -q e.txt && echo "{\"a\":1}" | jq -e ".a==1" >/dev/null'
step "1 GiB write/hash" bash -c 'dd if=/dev/zero of=big.bin bs=1M count=1024 status=none && sha256sum big.bin >/dev/null && rm big.bin'
