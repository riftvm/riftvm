source "$(dirname "$0")/../lib.sh"
mkdir -p ~/devday && cd ~/devday
export CI=1 npm_config_yes=true
step "node/npm" bash -c 'node -v && npm -v'
step "npm create vite react-ts" bash -c 'rm -rf web; timeout 180 npm create -y vite@latest web -- --template react-ts --no-interactive </dev/null >/tmp/cv.log 2>&1; test -f web/package.json || { tail -3 /tmp/cv.log; exit 1; }'
cd web || exit 1
step "npm install" npm install --no-audit --no-fund
step "npm run build" npm run build
step "vite dev + curl" bash -c 'npx vite --port 5173 --strictPort >/tmp/vite.log 2>&1 & p=$!; for i in $(seq 1 60); do curl -sf localhost:5173 >/dev/null && break; sleep 0.5; done; curl -sf localhost:5173 | grep -q "<div id=\"root\">"; r=$?; kill $p; exit $r'
step "HMR on file change" bash -c 'npx vite --port 5174 --strictPort --clearScreen false >/tmp/vite2.log 2>&1 & p=$!; sleep 4; curl -sf localhost:5174/src/App.tsx >/dev/null; echo "// touched" >> src/App.tsx; sleep 3; kill $p; grep -qi "hmr update\|page reload" /tmp/vite2.log'
step "chromium headless renders app" bash -c 'npm run build >/dev/null; npx vite preview --port 4173 --strictPort >/tmp/prev.log 2>&1 & p=$!; for i in $(seq 1 40); do curl -sf localhost:4173 >/dev/null && break; sleep 0.5; done; timeout 60 chromium --headless=new --no-sandbox --virtual-time-budget=5000 --dump-dom http://localhost:4173 2>/dev/null > /tmp/dom.html; kill $p; grep -q "id=\"root\"><" /tmp/dom.html'
step "vitest" bash -c 'npm i -D vitest --no-audit --no-fund >/dev/null && printf "import {expect,test} from \"vitest\"\ntest(\"adds\",()=>expect(1+1).toBe(2))\n" > src/sum.test.ts && npx vitest run'
step "eslint" npm run lint
step "prettier" bash -c 'npx -y prettier --write src/main.tsx >/dev/null && npx -y prettier --check src/main.tsx'
step "tsc -b" npx tsc -b
step "pnpm" bash -c 'npm i -g pnpm >/dev/null && cd .. && rm -rf web2 && cp -r web web2 && cd web2 && rm -rf node_modules package-lock.json && pnpm install --silent && pnpm run build >/dev/null'
step "bun (mise)" bash -c 'mise use -g bun@latest >/dev/null 2>&1; eval "$(mise env -s bash)"; cd .. && rm -rf web3 && cp -r web web3 && cd web3 && rm -rf node_modules package-lock.json && bun install >/dev/null && bun run build >/dev/null'
step "tailwind v4" bash -c 'npm i -D tailwindcss @tailwindcss/vite --no-audit --no-fund >/dev/null && sed -i "s#^import react from .*#&\nimport tailwindcss from \"@tailwindcss/vite\"#; s#plugins: \[react()\]#plugins: [react(), tailwindcss()]#" vite.config.ts && echo "@import \"tailwindcss\";" > src/index.css && npm run build >/dev/null'
step "playwright-core + chromium" bash -c 'npm i -D playwright-core --no-audit --no-fund >/dev/null && node -e "const {chromium}=require(\"playwright-core\");(async()=>{const b=await chromium.launch({executablePath:\"/usr/bin/chromium\",args:[\"--no-sandbox\"]});const p=await b.newPage();await p.setContent(\"<h1>ok</h1>\");const t=await p.textContent(\"h1\");await b.close();if(t!==\"ok\")process.exit(1)})()"'
step "next.js create+build" bash -c 'cd .. && rm -rf nx && timeout 600 npx -y create-next-app@latest nx --ts --eslint --app --no-src-dir --no-tailwind --import-alias "@/*" --use-npm --yes </dev/null >/tmp/nx.log 2>&1 && cd nx && npm run build >/tmp/nxb.log 2>&1'
