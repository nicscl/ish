#!/bin/sh
# Usage: tools/perf/profile.sh [workload...]  (default: all)
# Records a Time Profiler trace of each workload and prints where the time went.
# Runs in $ISH_PROF_DATA (a directory holding the fakefs root, see README.md).
set -e
here=$(cd "$(dirname "$0")" && pwd)
cd "${ISH_PROF_DATA:?set ISH_PROF_DATA to the directory holding root/}"
ISH=${ISH:-ish}
mkdir -p traces
for w in ${@:-apk git gcc python fork cpu}; do
  rm -rf traces/$w.trace
  xcrun xctrace record --quiet --template 'Time Profiler' --output traces/$w.trace --launch -- "$ISH" -f root /prof/run.sh $w >/dev/null 2>&1
  xcrun xctrace export --input traces/$w.trace --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > traces/$w.xml
  python3 "$here/analyze.py" traces/$w.xml
done
