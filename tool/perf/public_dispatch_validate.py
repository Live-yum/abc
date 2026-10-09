"""Coverage contract for the real-controller/public-fixture performance suite."""

REQUIRED = {
    'catalog.import': 'import', 'catalog.world-import': 'import',
    'bestiary.patch': 'stageBestiary', 'bestiary.entry': 'bestiaryEntry',
    'bestiary.unlock': 'bestiaryUnlockKnown', 'chests.catalog-slot': 'stageChest',
    'chests.best-prefix': 'chestBestPrefixes', 'public.world-export': 'export',
    'rules.preset-clone': 'worldPresetClone', 'pixel.prepare-canvas': 'resize',
    'pixel.prepare-paint': 'paint', 'pixel.match': 'pixelMatch',
    'placement.region-load': 'fusionRegion', 'placement.stage': 'fusionPlace',
    'placement.discard': 'fusionDiscardPlacement', 'placement.restage': 'fusionPlace',
    'placement.insert': 'fusionInsert', 'public.placement-readback': 'fusionRegion',
    'placement.undo': 'undo', 'catalog.player-import': 'import',
    'player.catalog-slot': 'playerSlotEdit', 'player.best-prefix': 'playerBestPrefixes',
    'player.catalog-export': 'export', 'conversion.import': 'import',
    'conversion.prepare': 'preparePlayerConversion',
    'conversion.cancel': 'cancelPlayerConversion',
    'conversion.reprepare': 'preparePlayerConversion',
    'conversion.apply': 'applyPlayerConversion', 'public.conversion-export': 'export',
    'conversion.undo': 'undo', 'cloud.prepare': 'cloudPrepareUpload',
    'cloud.discard': 'cloudDiscardUpload', 'cloud.reprepare': 'cloudPrepareUpload',
    'cloud.upload': 'cloudUploadPrepared', 'cloud.download': 'cloudDownload',
    'cloud.recommendation-download': 'cloudRecommendationDownload',
}


def validate_workload(report):
    methodology = report['methodology']
    cycles, warmup = methodology['measuredCycles'], methodology['warmupCycles']
    assert type(cycles) is int and cycles >= 3, 'At least three measured cycles required'
    assert type(warmup) is int and warmup >= 1, 'An excluded warmup is required'
    fixtures = {row['id'] for row in report['fixtures']}
    assert fixtures == {'public-modern-world', 'public-catalog',
                        'public-player-v326', 'public-player-v279'}, 'Unexpected public fixture inventory'
    rows = report['operations']
    keys = [(row['id'], row['phase']) for row in rows]
    expected = {(f'workspace.{scenario}', phase) for scenario in REQUIRED
                for phase in ('cold', 'warm')}
    assert len(keys) == len(set(keys)) and set(keys) == expected, 'Missing or duplicate declared dispatcher variant/phase'
    for row in rows:
        scenario = row['id'].removeprefix('workspace.')
        assert row.get('controller') == 'Workspace' and row.get('action') == REQUIRED[scenario], 'Dispatcher identity differs from the workload contract'
        assert row.get('dispatchEvidence') == 'awaited-production-dispatch', 'Core timing is not a dispatch sample'
        assert row.get('completion') == 'returned-and-state-asserted', 'State-checked completion required'
        assert row.get('fixture') in fixtures, 'Undeclared fixture'
        assert row['iterations'] == (1 if row['phase'] == 'cold' else cycles), 'Incomplete dispatcher repetitions'
        assert row['warmup'] == (0 if row['phase'] == 'cold' else warmup), 'Incorrect warmup accounting'
        assert 'frameCount' not in row, 'Controller-only timings cannot claim profile frames'
    closed = [row for row in report['memory'] if row['phase'] == 'after-close']
    assert sorted(row['cycle'] for row in closed) == list(range(-1, warmup + cycles)), 'Missing or duplicate lifecycle cleanup memory'
    assert all(row.get('ownedHandles') == 0 and row.get('rssBytes', 0) > 0 for row in closed), 'Unclosed owners or unavailable process RSS'
