#!/usr/bin/env python3
"""Bucket an xctrace time-profile export of the iSH CLI by where time goes."""
import sys, re, collections, xml.etree.ElementTree as ET

def load(path):
    root = ET.parse(path).getroot()
    frames, stacks, weights = {}, {}, {}
    samples = []
    for row in root.iter('row'):
        w = row.find('weight')
        if w is None: continue
        wid, wref = w.get('id'), w.get('ref')
        weight = int(w.text) if w.text else weights[wref]
        if wid: weights[wid] = weight
        bt = row.find('tagged-backtrace')
        if bt is None: bt = row.find('backtrace')
        if bt is None:
            samples.append((weight, [])); continue
        if bt.get('ref'):
            samples.append((weight, stacks[bt.get('ref')])); continue
        names = []
        for f in bt.iter('frame'):
            if f.get('ref'):
                names.append(frames[f.get('ref')])
            else:
                frames[f.get('id')] = f.get('name') or f.get('addr')
                names.append(frames[f.get('id')])
        stacks[bt.get('id')] = names
        samples.append((weight, names))
    return samples

def has(stack, pat):
    return any(re.search(pat, n or '') for n in stack)

def bucket(stack):
    leaf = stack[0] if stack else ''
    if has(stack, r'^handle_interrupt$'):
        if has(stack, r'sqlite3|^fakefs_|^db_'): return 'kernel: fakefs sqlite'
        if has(stack, r'^(sys_execve|sys_clone|sys_fork|sys_vfork|mm_copy|pt_copy_on_write|do_exit|mm_release|mem_destroy|sys_exit)'):
            return 'kernel: fork/exec/exit'
        if has(stack, r'^(sys_mmap|sys_munmap|sys_mprotect|sys_brk|mmap_common|handle_page_fault|mem_segv_reason)'):
            return 'kernel: mmap/brk/faults'
        return 'kernel: other syscalls'
    if has(stack, r'^(fiber_block_compile|gen_step|gen_|decode)'): return 'engine: translate blocks'
    if has(stack, r'^cpu_run_to_interrupt$'):
        if re.search(r'tlb|mem_ptr|mem_pt', leaf): return 'engine: TLB/memory'
        if re.search(r'fiber_lookup|fiber_insert|fiber_resize', leaf): return 'engine: block lookup'
        if re.search(r'fpu|f80|vec_|mmx', leaf): return 'engine: FPU/SSE helpers'
        if re.search(r'asbestos_invalidate|fiber_block_free|fiber_block_disconnect|jetsam', leaf): return 'engine: invalidation'
        return 'engine: executing gadgets'
    return 'other (startup, host runtime)'

def sysname(stack):
    for n in reversed(stack):
        if n and re.match(r'^sys_[a-z0-9_]+$', n): return n
    return None

def main():
    path = sys.argv[1]
    samples = load(path)
    total = sum(w for w, _ in samples) or 1
    by = collections.Counter(); leaves = collections.Counter(); calls = collections.Counter()
    for w, st in samples:
        b = bucket(st); by[b] += w
        leaves[st[0] if st else '?'] += w
        if b.startswith('kernel'):
            s = sysname(st)
            if s: calls[s] += w
    print(f'{path}: {total/1e9:.2f}s sampled CPU')
    for b, w in by.most_common(): print(f'  {100*w/total:5.1f}%  {b}')
    print('  top syscalls:', ', '.join(f'{s} {100*w/total:.1f}%' for s, w in calls.most_common(6)))
    print('  top leaf functions:', ', '.join(f'{s} {100*w/total:.1f}%' for s, w in leaves.most_common(8)))

main()
