source "$(dirname "$0")/../lib.sh"
mkdir -p ~/devday && cd ~/devday
step "python venv + pip" bash -c 'python3 -m venv venv && . venv/bin/activate && pip install -q requests && python -c "import requests"'
step "uv (pacman) project" bash -c 'sudo pacman -S --noconfirm --needed uv >/dev/null && rm -rf uvp && uv init -q uvp && cd uvp && uv add -q httpx && uv run python -c "import httpx"'
step "C with make" bash -c 'mkdir -p c && cd c && printf "#include <stdio.h>\nint main(){puts(\"hi\");}\n" > m.c && printf "m: m.c\n\tcc -O2 -o m m.c\n" > Makefile && make -s && ./m | grep -qx hi'
step "go (pacman) build" bash -c 'sudo pacman -S --noconfirm --needed go >/dev/null && mkdir -p g && cd g && (go mod init ex >/dev/null 2>&1; true) && printf "package main\nimport \"fmt\"\nfunc main(){fmt.Println(\"go ok\")}\n" > main.go && go run . | grep -q "go ok"'
step "rust (mise) cargo run" bash -c 'mise use -g rust@stable >/tmp/rust.log 2>&1; eval "$(mise env -s bash)"; rm -rf r && cargo new -q r && cd r && cargo run -q | grep -q "Hello, world"'
step "docker enable" bash -c 'sudo systemctl enable --now docker.service >/dev/null 2>&1 && systemctl is-active docker'
step "docker hello-world" bash -c 'sudo docker run --rm hello-world | grep -q "Hello from Docker"'
step "docker build+run" bash -c 'mkdir -p dk && cd dk && printf "FROM alpine:3\nCMD [\"echo\", \"container ok\"]\n" > Dockerfile && sudo docker build -q -t devday . >/dev/null && sudo docker run --rm devday | grep -q "container ok"'
step "docker compose postgres" bash -c 'mkdir -p dc && cd dc && printf "services:\n  db:\n    image: postgres:17-alpine\n    environment:\n      POSTGRES_PASSWORD: pw\n" > compose.yaml && sudo docker compose up -d >/dev/null 2>&1 && for i in $(seq 1 30); do sudo docker compose exec -T db pg_isready -U postgres >/dev/null 2>&1 && break; sleep 2; done; sudo docker compose exec -T db psql -U postgres -tc "select 1" | grep -q 1; r=$?; sudo docker compose down >/dev/null 2>&1; exit $r'
step "pacman uninstall" bash -c 'sudo pacman -Rns --noconfirm go >/dev/null && ! command -v go'
step "yay AUR build+remove" bash -c 'timeout 600 yay -S --noconfirm --needed --answerdiff None --answerclean None --answeredit None --removemake tty-clock >/tmp/yay.log 2>&1 && pacman -Q tty-clock && sudo pacman -Rns --noconfirm tty-clock >/dev/null'
step "VS Code install (omarchy)" bash -c 'timeout 900 omarchy-pkg-add visual-studio-code-bin >/tmp/code.log 2>&1; code --version | head -1'
