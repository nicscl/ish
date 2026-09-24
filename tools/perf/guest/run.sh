#!/bin/sh
# Usage: run.sh <workload>
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root
case "$1" in
  apk)    apk add -q --no-network --allow-untrusted /prof/pkgs/*.apk && apk del -q vim ;;
  git)    cd /prof/repo && for i in 1 2 3; do git status --short >/dev/null; done ;;
  gcc)    cd /tmp && for i in 1 2 3; do gcc -O2 -o hello /prof/hello.c; done && ./hello ;;
  python) for i in 1 2 3 4 5; do python3 -c pass; done ;;
  fork)   for i in $(seq 300); do /bin/true; done; for i in $(seq 100); do echo x | grep -c x >/dev/null; done ;;
  cpu)    python3 -c 'print(sum(i*i for i in range(3000000)))' ;;
  *) echo "unknown workload: $1"; exit 1 ;;
esac
