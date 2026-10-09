"""Known Linux Dart ProcessInfo sampling semantics, shared by both diagnostics.

Only the cross-source, sequential ProcessInfo pair is covered. Same-source OS
status bounds and isolate-group heap bounds stay strict in their validators.
"""

FLUTTER_REVISION = '5fc346839b5d0eef006ed8404392afb4dfae428d'
SDK_REVISION = '04bcd1036cdc799ac6564988f159ee454d42c822'
SDK_SOURCE = ('https://github.com/dart-lang/sdk/blob/' + SDK_REVISION
              + '/runtime/bin/process_linux.cc#L975')
KERNEL_SOURCE = 'https://www.kernel.org/doc/html/latest/filesystems/proc.html'


def process_info_disagreement(vm, point, runtime):
    """Keep raw disagreement as an observation, never a stability pass."""
    if vm['heapUsedBytes'] > vm['heapCapacityBytes']:
        raise ValueError('VM heap capacity bound invalid')
    if vm['rssBytes'] <= vm['maxRssBytes']:
        return None
    if (point.get('atomic') is not False or runtime.get('platform') != 'linux'
            or runtime.get('flutterRevisionPin') != FLUTTER_REVISION):
        raise ValueError('RSS high-water bound invalid for unverified sampling source')
    start = point.get('slotStartUs', point.get('vmStartUs'))
    end = point.get('slotEndUs', point.get('vmEndUs'))
    if type(start) is not int or type(end) is not int or not 0 <= start <= end:
        raise ValueError('RSS disagreement has no valid sampling window')
    return {
        'kind': 'non-atomic-cross-source-rss-hwm-disagreement',
        'cycle': point['cycle'], 'phase': point['phase'],
        'rssBytes': vm['rssBytes'], 'maxRssBytes': vm['maxRssBytes'],
        'rssMinusReportedMaxBytes': vm['rssBytes'] - vm['maxRssBytes'],
        'samplingWindowUs': [start, end], 'atomic': False,
        'rssSource': 'Dart ProcessInfo.currentRss: /proc/self/statm resident pages',
        'maxRssSource': 'Dart ProcessInfo.maxRss: getrusage(RUSAGE_SELF).ru_maxrss',
        'readOrder': ['currentRss', 'maxRss'],
        'sdkRevision': SDK_REVISION, 'sdkSource': SDK_SOURCE,
        'kernelAccountingSource': KERNEL_SOURCE,
        'interpretation': 'Raw values retained; neither is substituted for the other. No plateau or leak conclusion.',
    }
