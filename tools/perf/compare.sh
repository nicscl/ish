#!/bin/zsh
# Usage: tools/perf/compare.sh [workload...]  (default: all)
# Runs each workload on asbestos and on the Unicorn engine and reports CPU and wall time.
# $ISH must be built with -Dunicorn=enabled; runs in $ISH_PROF_DATA (see README.md).
cd "${ISH_PROF_DATA:?set ISH_PROF_DATA to the directory holding root/}"
ISH=${ISH:-ish}
ws=("$@"); (( $#ws )) || ws=(cpu python gcc git fork apk)
for w in $ws; do
  for v in asbestos unicorn; do
    out=$(env ISH_ENGINE=$v UC_NO_MEMOP_EXIT_CHECK=1 /usr/bin/time -p perl -e 'alarm 900; exec @ARGV' $ISH -f root /prof/run.sh $w 2>&1)
    st=$?
    cpu=$(echo "$out" | awk '/^user|^sys/{s+=$2} END{printf "%.2f", s}')
    real=$(echo "$out" | awk '/^real/{print $2}')
    tail=$(echo "$out" | grep -vE '^(real|user|sys) ' | tail -1)
    printf "%-7s %-9s cpu=%7ss wall=%7ss exit=%s %s\n" $w $v $cpu $real $st "${tail:0:50}"
  done
done
