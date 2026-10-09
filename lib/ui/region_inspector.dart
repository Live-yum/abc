import 'package:flutter/material.dart';

/// Stateless all-layer inspector. The parent owns selection/history/save actions.
class RegionInspector extends StatelessWidget {
  final Map<String, int>? tile;
  final ValueChanged<Map<String, int>> onChanged;
  const RegionInspector({
    super.key,
    required this.tile,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) {
    final value = tile;
    if (value == null) return const Text('选择一个格子查看所有图层');
    const fields = {
      'block': '物块 ID',
      'wall': '背景墙 ID',
      'blockPaint': '物块涂漆',
      'wallPaint': '墙壁涂漆',
      'liquid': '液体量 0–255',
      'liquidType': '液体 0无 1水 2岩浆 3蜂蜜 4微光',
      'slope': '形状 0–7',
      'wires': '导线位掩码 红1 蓝2 绿4 黄8',
    };
    const flags = {
      'active': '物块存在',
      'actuator': '制动器',
      'inactive': '虚化',
      'invisibleBlock': '物块隐形',
      'invisibleWall': '墙壁隐形',
      'fullbrightBlock': '物块全亮',
      'fullbrightWall': '墙壁全亮',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '格子 ${value['x']}, ${value['y']} · 帧 ${value['frameX']}, ${value['frameY']}',
        ),
        const Text('家具结构及实体由引擎校验；拒绝操作会保留原世界。'),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            for (final f in fields.entries)
              SizedBox(
                width: 180,
                child: TextFormField(
                  key: ValueKey(
                    '${value['x']}:${value['y']}:${f.key}:${value[f.key]}',
                  ),
                  initialValue: '${value[f.key] ?? 0}',
                  decoration: InputDecoration(labelText: f.value),
                  keyboardType: TextInputType.number,
                  onFieldSubmitted: (text) {
                    final n = int.tryParse(text);
                    if (n != null) onChanged({f.key: n});
                  },
                ),
              ),
          ],
        ),
        Wrap(
          children: [
            for (final f in flags.entries)
              SizedBox(
                width: 180,
                child: CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(f.value),
                  value: value[f.key] == 1,
                  onChanged: (v) => onChanged({f.key: v == true ? 1 : 0}),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
