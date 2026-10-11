"""Synthetic process/output faults only; never starts an application."""
import json
import os
import resource
import signal
import sys
import time

mode = sys.argv[1]
if mode == 'success':
    print(json.dumps({'pid': os.getpid(), 'pgid': os.getpgrp(),
                      'fileLimit': resource.getrlimit(resource.RLIMIT_FSIZE)[0],
                      'coreLimit': resource.getrlimit(resource.RLIMIT_CORE)[0],
                      'envKeys': sorted(os.environ)}), flush=True)
elif mode == 'fastfail':
    print('partial evidence', flush=True)
    sys.exit(7)
elif mode == 'flood':
    os.write(1, b'x' * int(sys.argv[2]))
elif mode == 'hang':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    print('before hang', flush=True)
    while True:
        time.sleep(1)
elif mode == 'child':
    child = os.fork()
    if child == 0:
        while True:
            time.sleep(1)
    print(json.dumps({'child': child}), flush=True)
    def terminate(sig, frame):
        os.waitpid(child, 0)
        sys.exit(0)
    signal.signal(signal.SIGTERM, terminate)
    while True:
        time.sleep(1)
else:
    raise SystemExit('unknown synthetic fixture mode')
