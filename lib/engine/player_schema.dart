/// Explicit empty state for the known release-326 player schema. No user save
/// or game assets are included. The engine validates this model before encoding.
Map<String, dynamic> blankPlayer(String name) {
  List<Map<String, dynamic>> items(int count) => List.generate(
    count,
    (_) => {'itemType': 0, 'stack': 0, 'prefix': 0, 'favorited': false},
  );
  final d = <String, dynamic>{
    'version': 326,
    'name': name,
    'metadata': {
      'magicAndType': '244154697780061554',
      'revision': 0,
      'favoriteFlags': 0,
    },
    'statLife': 100,
    'statLifeMax': 100,
    'statMana': 20,
    'statManaMax': 20,
    'voiceVariant': 1,
    'tailLayout': {'builderAccStatusCount': 12, 'includesDeathMetadata': true},
    'hideVisibleAccessory': List.filled(10, false),
    'hideInfo': List.filled(13, false),
    'dpadRadialBindings': List.filled(4, 0),
    'builderAccStatus': List.filled(12, 0),
    'spawnPoints': [],
    'creativeItemSacrifices': [],
    'temporarySlots': List.filled(4, null),
    'pendingRefunds': [],
    'oneTimeDialoguesSeen': [],
    'respawnTimer': null,
    'buffs': List.generate(44, (_) => {'buffType': 0, 'buffTime': 0}),
    'loadouts': List.generate(
      3,
      (_) => {
        'armor': items(20),
        'dyes': items(10),
        'hide': List.filled(10, false),
      },
    ),
    'creativePowers': {
      'godmodeEnabled': false,
      'farPlacementEnabled': false,
      'spawnRateSlider': 0.5,
    },
  };
  for (final key
      in 'difficulty playTimeTicks hair hairDye team hideMisc skinVariant taxMoney numberOfDeathsPve numberOfDeathsPvp voidVaultInfo anglerQuestsFinished bartenderQuestLog lastSaveUtcTicks golferScoreAccumulated currentLoadoutIndex voicePitchOffset'
          .split(' ')) {
    d[key] = 0;
  }
  for (final key
      in 'extraAccessory unlockedBiomeTorches usingBiomeTorches ateArtisanBread usedAegisCrystal usedAegisFruit usedArcaneCrystal usedGalaxyPearl usedGummyWorm usedAmbrosia downedDd2EventAnyDifficulty hbLocked dead creativeTrackerHasNewUnlocks unlockedSuperCart enabledSuperCart'
          .split(' ')) {
    d[key] = false;
  }
  for (final entry in {
    'armor': 20,
    'dyes': 10,
    'inventory': 58,
    'miscEquips': 5,
    'miscDyes': 5,
    'piggyBank': 40,
    'safe': 40,
    'defendersForge': 40,
    'voidVault': 40,
  }.entries) {
    d[entry.key] = items(entry.value);
  }
  for (final key in [
    'hairColor',
    'skinColor',
    'eyeColor',
    'shirtColor',
    'underShirtColor',
    'pantsColor',
    'shoeColor',
  ]) {
    d[key] = {'r': 128, 'g': 128, 'b': 128};
  }
  return d;
}
