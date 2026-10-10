// Test-only physical computer fixture. Never import into production lib.
import 'dart:typed_data';

import 'package:terraforge/engine/world_circuit_backend.dart';

/// Physical layout of the source-verified 2026-08-03 Computerraria world.
/// These are wiring controls and lamp coordinates, not a host CPU emulator.
class ComputerrariaComputer {
  static const sourceSha256 =
      '55d0a24bd1f56d622003dbd30d52555e7d06d6d1bcacfc22ae506f2db5240c33';
  static const romBytes = 768 * 1024;
  static const ramBytes = 368 * 1024;
  static const mono = ComputerDisplayRegion('黑白显示器', 6485, 800, 64, 48);

  static WorldCircuitCommand clock([int pulses = 1]) =>
      WorldCircuitCommand.trigger(
        3194,
        153,
        mask: 8,
        pulses: pulses,
        hitSwitch: false,
      );
  static WorldCircuitCommand resetSignal() =>
      WorldCircuitCommand.trigger(3198, 156, mask: 4, hitSwitch: false);
  static WorldCircuitCommand ready() =>
      WorldCircuitCommand.lamps([3199, 156, 0, 0]);
  static List<WorldCircuitCommand> get resetBus => [
    WorldCircuitCommand.trigger(3243, 226, mask: 2, hitSwitch: false),
    WorldCircuitCommand.trigger(3404, 350, mask: 2, hitSwitch: false),
    WorldCircuitCommand.trigger(3198, 198, mask: 8, hitSwitch: false),
  ];

  /// Independently calibrated by a program reading the physical input bus.
  /// Repeated pulses are sticky until a CPU read; release sends no pulse.
  static WorldCircuitCommand key(String direction) => switch (direction) {
    'up' => WorldCircuitCommand.trigger(6516, 851, mask: 9, hitSwitch: false),
    'down' => WorldCircuitCommand.trigger(6517, 866, mask: 5, hitSwitch: false),
    'left' => WorldCircuitCommand.trigger(
      6519,
      858,
      mask: 10,
      hitSwitch: false,
    ),
    'right' => WorldCircuitCommand.trigger(
      6520,
      857,
      mask: 5,
      hitSwitch: false,
    ),
    _ => throw const FormatException('未知的计算机方向键。'),
  };

  static bool isReady(WorldCircuitResult response) {
    if (response.records.length != 16) {
      throw const FormatException('计算机就绪灯返回了不完整数据。');
    }
    final d = ByteData.sublistView(response.records);
    if (d.getUint32(0, Endian.little) != 3199 ||
        d.getUint32(4, Endian.little) != 156 ||
        d.getUint32(12, Endian.little) != 419) {
      throw const FormatException('计算机就绪灯与已核验布局不匹配。');
    }
    return d.getUint32(8, Endian.little) == 1;
  }

  static (int, int) romLamp(int byteAddress, int bit) {
    if (byteAddress < 0 || byteAddress >= romBytes || bit < 0 || bit > 31) {
      throw RangeError('ROM address or bit out of range');
    }
    final word = byteAddress ~/ 4, cell = word % 8192, bank = word ~/ 8192;
    return (2853 + cell + (cell + 1) ~/ 2, 1143 + 131 * bank + 3 * (31 - bit));
  }

  static (int, int) ramLamp(int byteAddress, int bit, {int mirror = 0}) {
    if (byteAddress < 0x100000 ||
        byteAddress >= 0x100000 + ramBytes ||
        bit < 0 ||
        bit > 31 ||
        mirror < 0 ||
        mirror > 1) {
      throw RangeError('RAM address, bit or mirror out of range');
    }
    final word = (byteAddress - 0x100000) ~/ 4;
    return (
      2853 + 3 * (word % 4096) + mirror,
      4287 + 125 * (word ~/ 4096) + 3 * (31 - bit),
    );
  }

  /// Reject executable containers; a flat ROM image must come from objcopy.
  static Uint8List parseProgram(String name, Uint8List input) {
    if (input.length >= 4 &&
        input[0] == 0x7f &&
        input[1] == 0x45 &&
        input[2] == 0x4c &&
        input[3] == 0x46) {
      throw const FormatException(
        '请将 ELF 用 objcopy -O binary 转为从地址 0 开始的 RV32I .bin。',
      );
    }
    Uint8List bytes;
    if (name.toLowerCase().endsWith('.txt')) {
      if (input.length > romBytes * 4) {
        throw const FormatException('十六进制程序超过 ROM 容量。');
      }
      final capacity = (input.length + 1) ~/ 2;
      final decoded = Uint8List(capacity < romBytes ? capacity : romBytes);
      var count = 0, digits = 0, value = 0;
      void emit() {
        if (count >= romBytes) throw const FormatException('十六进制程序超过 ROM 容量。');
        decoded[count++] = value;
        digits = 0;
        value = 0;
      }

      for (final byte in input) {
        final whitespace = byte == 32 || (byte >= 9 && byte <= 13);
        if (whitespace) {
          if (digits == 1) throw const FormatException('每个十六进制字节必须为两位。');
          if (digits == 2) emit();
          continue;
        }
        final nibble = byte >= 48 && byte <= 57
            ? byte - 48
            : byte >= 65 && byte <= 70
            ? byte - 55
            : byte >= 97 && byte <= 102
            ? byte - 87
            : -1;
        if (nibble < 0 || digits == 2) {
          throw const FormatException('程序文本必须是空白分隔的两位十六进制字节。');
        }
        value = (value << 4) | nibble;
        digits++;
      }
      if (digits == 1) throw const FormatException('每个十六进制字节必须为两位。');
      if (digits == 2) emit();
      bytes = Uint8List.sublistView(decoded, 0, count);
    } else if (name.toLowerCase().endsWith('.bin')) {
      bytes = input;
    } else {
      throw const FormatException('请选择 RV32I .bin 或十六进制 .txt 程序。');
    }
    if (bytes.isEmpty || bytes.length > romBytes) {
      throw const FormatException('程序必须为 1 字节到 768 KiB，加载起点为 ROM 地址 0。');
    }
    final padded = Uint8List((bytes.length + 3) ~/ 4 * 4);
    padded.setAll(0, bytes);
    return padded;
  }

  /// Delta writes also clear the old program's tail. Original verified ROM is
  /// zero; cancelled partial writes require reimport before another program.
  static Iterable<List<int>> programWrites(
    Uint8List before,
    Uint8List after, {
    int batchLamps = 8192,
  }) sync* {
    if (before.length > romBytes ||
        after.length > romBytes ||
        before.length % 4 != 0 ||
        after.length % 4 != 0 ||
        batchLamps < 1 ||
        batchLamps > 65536) {
      throw const FormatException('Invalid program patch bounds');
    }
    final oldData = ByteData.sublistView(before),
        newData = ByteData.sublistView(after);
    final length = before.length > after.length ? before.length : after.length;
    var records = <int>[];
    for (var address = 0; address < length; address += 4) {
      final oldWord = address < before.length
          ? oldData.getUint32(address, Endian.little)
          : 0;
      final newWord = address < after.length
          ? newData.getUint32(address, Endian.little)
          : 0;
      final changed = oldWord ^ newWord;
      if (changed == 0) continue;
      for (var bit = 0; bit < 32; bit++) {
        if ((changed & (1 << bit)) == 0) continue;
        final (x, y) = romLamp(address, bit);
        records.addAll([x, y, (newWord >> bit) & 1, 0]);
        if (records.length == batchLamps * 4) {
          yield records;
          records = <int>[];
        }
      }
    }
    if (records.isNotEmpty) yield records;
  }
}

class ComputerDisplayRegion {
  final String name;
  final int x, y, width, height;
  const ComputerDisplayRegion(
    this.name,
    this.x,
    this.y,
    this.width,
    this.height,
  );

  Uint8List decode(WorldCircuitResult response) {
    if (response.resultKind != 9 ||
        response.records.length != width * height * 16) {
      throw const FormatException('显示器像素数量与已核验布局不匹配。');
    }
    final out = Uint8List(width * height * 4), seen = Uint8List(width * height);
    final d = ByteData.sublistView(response.records);
    for (var at = 0; at < response.records.length; at += 16) {
      final px = d.getUint32(at, Endian.little) - x;
      final py = d.getUint32(at + 4, Endian.little) - y;
      final tile = d.getUint32(at + 8, Endian.little) & 65535;
      final fx = d.getInt16(at + 12, Endian.little),
          fy = d.getInt16(at + 14, Endian.little);
      if (px < 0 ||
          py < 0 ||
          px >= width ||
          py >= height ||
          tile != 445 ||
          fx < 0 ||
          fx % 18 != 0 ||
          fy < 0 ||
          fy % 18 != 0 ||
          (fx > 18 || fy != 0)) {
        throw const FormatException('显示器返回了无效的实际像素状态。');
      }
      final index = py * width + px;
      if (seen[index] != 0) throw const FormatException('显示器像素重复。');
      seen[index] = 1;
      final rgb = fx == 18 ? 0xffffff : 0;
      out[index * 4] = (rgb >> 16) & 255;
      out[index * 4 + 1] = (rgb >> 8) & 255;
      out[index * 4 + 2] = rgb & 255;
      out[index * 4 + 3] = 255;
    }
    return out;
  }
}
