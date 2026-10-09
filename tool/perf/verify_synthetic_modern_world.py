#!/usr/bin/env python3
"""Small real-codec correctness preflight; it is not a benchmark result."""
import argparse
import ctypes
import hashlib
import json

from generate_synthetic_modern_world import world_bytes


def verify(library):
    core = ctypes.CDLL(str(library))
    source = world_bytes()
    source_hash = hashlib.sha256(source).hexdigest()
    handles = set()

    def check(code):
        if code:
            size = ctypes.c_uint32()
            core.abc_error(None, 0, ctypes.byref(size))
            output = ctypes.create_string_buffer(size.value)
            core.abc_error(output, size.value, ctypes.byref(size))
            raise AssertionError(output.value.decode())

    def open_world(data):
        handle = ctypes.c_uint32()
        check(core.abc_world_open(data, len(data), ctypes.byref(handle)))
        handles.add(handle.value)
        return handle.value

    def close_world(handle):
        check(core.abc_world_close(handle))
        handles.remove(handle)

    def output(call):
        size = ctypes.c_uint32()
        check(call(None, 0, ctypes.byref(size)))
        data = ctypes.create_string_buffer(size.value)
        check(call(data, size.value, ctypes.byref(size)))
        return data.raw[:size.value]

    def section(handle, name):
        return json.loads(output(lambda data, size, required:
            core.abc_world_section(handle, name.encode(), data, size, required)).rstrip(b'\0'))

    def operation(handle, name, args):
        output(lambda data, size, required: core.abc_world_operation(
            handle, name.encode(), json.dumps(args).encode(), data, size, required))

    try:
        original = open_world(source)
        header = section(original, 'header')
        assert (header['maxTilesX'], header['maxTilesY']) == (16, 32)
        assert section(original, 'bestiary') == {'kills': [], 'sightings': [], 'chats': []}
        baseline_chests = section(original, 'chests')
        assert len(baseline_chests) == 1 and len(baseline_chests[0]['items']) == 40
        chests = json.loads(json.dumps(baseline_chests))
        chests[0]['items'][0]['prefix'] = 2
        bestiary = {'kills': [{'persistentNpcId': 'SyntheticCreature', 'killCount': 50},
                              {'persistentNpcId': 'SyntheticUnknown', 'killCount': 7}],
                    'sightings': [], 'chats': []}
        operation(original, 'replace_chests', {'chests': chests})
        operation(original, 'replace_bestiary', bestiary)
        saved = output(lambda data, size, required:
            core.abc_world_save(original, data, size, required))
        close_world(original)
        reopened = open_world(saved)
        assert section(reopened, 'chests') == chests
        assert section(reopened, 'bestiary') == bestiary
        assert section(reopened, 'footer')['valid'] is True
        close_world(reopened)
        untouched = open_world(source)
        assert section(untouched, 'chests') == baseline_chests
        assert section(untouched, 'bestiary')['kills'] == []
        assert hashlib.sha256(source).hexdigest() == source_hash
        return {'status': 'passed', 'sourceBytes': len(source),
                'sourceSha256': source_hash, 'exportBytes': len(saved),
                'checks': ['header dimensions', 'chest prefix mutation readback',
                           'known and unknown bestiary record readback',
                           'independent save reopen', 'footer', 'unchanged source'],
                'scope': 'small real-native correctness preflight; no performance evidence'}
    finally:
        for handle in handles:
            check(core.abc_world_close(handle))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('library')
    args = parser.parse_args()
    print(json.dumps(verify(args.library), indent=2))
