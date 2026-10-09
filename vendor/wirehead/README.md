# WireHead reference

The optional circuit optimization mode references the ordinary PixelBox group-pair
algorithm in misprit7/WireHead, commit
`e6009d010ca54ff43d04b44697accc7115807b9c`, MIT © 2023 Xander Naumenko.
The complete permission notice is retained in LICENSE.

Reviewed files: `Accelerator.cs` (ordinary PixelBox network pairs and trigger
parity), `WiringWrapper.cs` (logic-gate wave boundaries). The implementation is
part of the vendored C engine and works on actual WLD networks; this directory
does not bundle or execute the mod, game runtime, textures or companion data.
The OFF path retains the separately verified game PixelBox behavior.
