"""Exact-range coverage of every retained bucket; never infer object ownership."""
from __future__ import annotations

CATEGORIES = ('unknownApplication', 'unknownNonFile', 'unknownSystem', 'allFunctionsKnown')


def summarize_coverage(endpoints, *, application_paths, engine_path):
    application_paths = frozenset(application_paths)
    if engine_path not in application_paths:
        raise ValueError('Engine identity must be an explicit application path')
    cuts = {}
    for cut in ('q0', 'q7'):
        total = [0] * 4
        partition = {key: {'bucketCount': 0, 'counters': [0] * 4} for key in CATEGORIES}
        inclusive = {key: {'bucketCount': 0, 'counters': [0] * 4} for key in CATEGORIES[:-1]}
        engine_pcs, unresolved_engine = set(), set()
        for bucket in endpoints['allStackBuckets']:
            if bucket.get(cut + 'Present') is False:
                continue
            counts = bucket[cut]
            if len(counts) != 4 or any(type(x) is not int or x < 0 for x in counts):
                raise ValueError('All four nonnegative integer bucket counters are required')
            if not bucket['frames']:
                raise ValueError('A full nonempty stack is required')
            unknown = set()
            for frame in bucket['frames']:
                module = frame.get('module')
                known = frame.get('functionKnown') is True
                names = frame.get('exactRangeSymbolCandidates', [])
                if (not isinstance(names, list) or any(not isinstance(name, str) or not name for name in names)
                        or known != bool(names)):
                    raise ValueError('Only exact-range candidates prove a known function')
                if module == engine_path:
                    pc = frame.get('elfOffset')
                    if type(pc) is not int or pc < 0:
                        raise ValueError('Engine PC requires its exact ELF offset')
                    engine_pcs.add(pc)
                    if not known:
                        unresolved_engine.add(pc)
                if not known:
                    unknown.add('unknownApplication' if module in application_paths else
                                'unknownNonFile' if module is None else 'unknownSystem')
            category = next((key for key in CATEGORIES if key in unknown), 'allFunctionsKnown')
            total = [a + b for a, b in zip(total, counts)]
            row = partition[category]
            row['bucketCount'] += 1
            row['counters'] = [a + b for a, b in zip(row['counters'], counts)]
            for key in unknown:
                row = inclusive[key]
                row['bucketCount'] += 1
                row['counters'] = [a + b for a, b in zip(row['counters'], counts)]
        for rows in (partition, inclusive):
            for row in rows.values():
                row['liveBlockFraction'] = row['counters'][0] / total[0] if total[0] else None
                row['liveByteFraction'] = row['counters'][1] / total[1] if total[1] else None
        if [sum(row['counters'][i] for row in partition.values()) for i in range(4)] != total:
            raise ValueError('Exclusive coverage partitions must match all original counters')
        cuts[cut] = {'totalCounters': total, 'exclusivePartition': partition,
                     'inclusiveUnknown': inclusive, 'inclusiveCategoriesMayOverlap': True,
                     'engine': {'observedDistinctPcs': len(engine_pcs),
                                'unresolvedElfOffsets': sorted(unresolved_engine),
                                'status': 'not-observed' if not engine_pcs else
                                          'failed' if unresolved_engine else 'exact-ranges-proven'}}
    return {'schema': 'abc.allocation-stack-coverage.v1', 'cuts': cuts,
            'counterOrder': ['liveBlocks', 'liveBytes', 'cumulativeBlocks', 'cumulativeBytes'],
            'classificationPriority': list(CATEGORIES),
            'functionNamesRequireExactRanges': True,
            'officialDecorativeNamesUsedForOwnership': False,
            'individualObjectSurvivalProven': False, 'retainingOwnerProven': False}


def verify_coverage_totals(coverage, first, last):
    for cut, profile in (('q0', first), ('q7', last)):
        if coverage['cuts'][cut]['totalCounters'] != list(profile['header']):
            raise ValueError('Coverage totals differ from complete original profile header')
    return True


def require_engine_coverage(coverage):
    if any(row['engine']['status'] == 'failed' for row in coverage['cuts'].values()):
        raise ValueError('Necessary engine PC lacks a proven exact function range')
    return True


def with_cut_presence(endpoints, first, last, modules):
    """Annotate a copy; the frozen exact endpoint-delta oracle stays unchanged."""
    from application_contract import normalized_file_pc
    keys = {}
    for cut, profile in (('q0', first), ('q7', last)):
        present = set()
        for bucket in profile['buckets']:
            stack = []
            for pc in bucket['stack']:
                candidates = [m for m in profile['maps']
                              if m['start'] <= pc < m['end'] and 'x' in m['permissions']]
                if len(candidates) != 1:
                    raise ValueError('Necessary PC must have exactly one executable mapping')
                mapping = candidates[0]
                path = mapping['path']
                stack.append(normalized_file_pc(pc, mapping, modules[path]) if path in modules
                             else ('unknown:' + (path or 'anonymous'), pc))
            present.add(tuple(stack))
        keys[cut] = present
    result = dict(endpoints)
    result['allStackBuckets'] = [dict(row,
        q0Present=tuple(tuple(k) for k in row['stack']) in keys['q0'],
        q7Present=tuple(tuple(k) for k in row['stack']) in keys['q7'])
        for row in endpoints['allStackBuckets']]
    if any(not row['q0Present'] and not row['q7Present'] for row in result['allStackBuckets']):
        raise ValueError('Endpoint stack absent from both complete original profiles')
    union = {tuple(tuple(k) for k in row['stack']) for row in result['allStackBuckets']}
    if union != keys['q0'] | keys['q7']:
        raise ValueError('Endpoint stack union differs from original profiles')
    return result
