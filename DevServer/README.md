# DevServer (OrbStack + Docker + Nginx)

This folder provides a minimal Nginx container to serve static files for tests.

- Exposes port 18080 on localhost
- Serves files from `/usr/share/nginx/html`
- Includes:
  - `hello.txt` for simple small download
  - `bigfile.bin` (10 MB) for range/resume/cancel tests

## Prerequisites

- [OrbStack](https://orbstack.dev/) installed (or Docker Desktop)
- macOS with zsh

## Usage

1. Prepare assets:

```zsh
./prepare.sh
```

2. Build and run the container via OrbStack (or Docker):

```zsh
# build image
orbstack docker build -t digger-nginx-dev .
# run with compose (maps 18080->80)
orbstack docker compose up -d
```

If you're using plain Docker instead of OrbStack, replace `orbstack docker` with `docker`.

3. Verify:

```zsh
curl -s http://127.0.0.1:18080/hello.txt
curl -i http://127.0.0.1:18080/status/404 | head -n1 # 404
curl -i http://127.0.0.1:18080/status/500 | head -n1 # 500
curl -I http://127.0.0.1:18080/redirect-hello         # 302 -> /hello.txt
curl -I http://127.0.0.1:18080/redirect1              # 302 -> 301 -> /hello.txt
curl -I http://127.0.0.1:18080/slow/bigfile.bin       # 200, but very slow
```

## Run tests

From project root:

```zsh
swift test
```

Tests will automatically skip if the server is not reachable.
