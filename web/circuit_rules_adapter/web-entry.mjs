import { createRulesFacade } from './rules-facade.mjs';
globalThis.createTerraCircuitRules = Module => createRulesFacade({
  Module,
  malloc(bytes) { const pointer = Module._tx_malloc(bytes); if (!pointer) throw new Error('Circuit WASM allocation failed'); return pointer; },
  free(pointer) { Module._tx_free(pointer); },
});
