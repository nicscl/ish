#!/bin/sh
set -e
mkdir -p /prof/pkgs && cd /prof/pkgs && apk fetch -R --no-progress vim >/dev/null
cp -r /usr/lib/python3.12 /prof/repo && cd /prof/repo && git init -q && git add -A && git -c user.email=a@b -c user.name=p commit -qm init
printf '#include <stdio.h>\nint main(void){puts("hi");return 0;}\n' > /prof/hello.c
echo "repo files: $(git ls-files | wc -l); pkgs: $(ls /prof/pkgs | wc -l)"
