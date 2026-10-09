import { createRulesFacade } from './rules-facade.mjs';
const facade = createRulesFacade({});
globalThis.TerraCircuitRules = Object.freeze({ invoke(method, args) {
  const result = facade.invoke(method, args);
  // This field describes the transport, not a device rule. The retained
  // source calls its native ABI "wasm" even when hosted by QuickJS + FFI.
  if (result && result.backend === 'wasm') result.backend = 'native';
  if (result && result.packet) {
    const packet = typeof result.packet === 'string' ? JSON.parse(result.packet) : result.packet;
    if (packet.native?.available && !packet.native.fallback) packet.native.backend = 'native';
    if (typeof result.packet === 'string') result.packet = JSON.stringify(packet);
  }
  return result;
} });
