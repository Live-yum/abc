import 'package:flutter/material.dart';

import '../platform/resource_store.dart';
import '../resources/online_resource_service.dart';

class OnlineResourcesPanel extends StatefulWidget {
  const OnlineResourcesPanel({
    super.key,
    this.service,
    required this.onActivate,
  });
  final OnlineResourceService? service;
  final void Function(ResourceStore store, void Function() assertUsable)
  onActivate;
  @override
  State<OnlineResourcesPanel> createState() => _OnlineResourcesPanelState();
}

class _OnlineResourcesPanelState extends State<OnlineResourcesPanel> {
  @override
  void initState() {
    super.initState();
    _restore();
  }

  @override
  void didUpdateWidget(OnlineResourcesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.service, oldWidget.service)) _restore();
  }

  Future<void> _restore() async {
    final service = widget.service;
    if (service == null) return;
    await service.initialize();
    if (!mounted || !identical(widget.service, service)) return;
    _activate(service);
  }

  void _activate(OnlineResourceService service) {
    final store = service.activeStore;
    if (store != null) widget.onActivate(store, service.assertActiveUsable);
  }

  Future<void> _install() async {
    final service = widget.service!;
    try {
      await service.install();
      if (mounted && identical(widget.service, service)) _activate(service);
    } catch (_) {
      /* The service exposes a bounded, actionable error state. */
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    if (service == null) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('线上资源尚未配置。请由应用配置受信任的 HTTPS 资源后台；也可继续导入本地 .abcpack。'),
      );
    }
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final active = service.activeStore;
        final phase = switch (service.phase) {
          'checking' => '检查审批状态与版本',
          'checked' => '版本已检查，可安装',
          'downloading' => '下载并校验资源',
          'verifying' => '校验本地资源并准备启用',
          'paused' => '下载已暂停，可继续安装',
          'error' => '安装未完成，可重试',
          'ready' => '资源已就绪',
          _ => '尚未安装线上资源',
        };
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('线上资源', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text('资源后台：${service.transport.authorityEndpoint}'),
            Text(phase, key: const Key('online-resource-phase')),
            if (active != null)
              Text(
                '已启用 Terraria ${active.catalog.gameVersion} · ${active.catalog.length} 条记录',
              ),
            if (service.available != null)
              Text('已审批版本：${service.available!.gameVersion}'),
            if (service.busy) ...[
              const LinearProgressIndicator(),
              Text(
                '已验证 ${service.completedObjects}/${service.totalObjects} 个对象 · ${(service.verifiedBytes / 1048576).toStringAsFixed(1)} MiB',
              ),
            ],
            if (service.error != null)
              Text(
                service.error!,
                key: const Key('online-resource-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: service.busy
                      ? null
                      : () async {
                          try {
                            await service.checkForUpdate();
                          } catch (_) {}
                        },
                  child: const Text('检查资源更新'),
                ),
                FilledButton(
                  onPressed: service.busy ? null : _install,
                  child: Text(
                    service.phase == 'paused' || service.phase == 'error'
                        ? '继续 / 重试安装'
                        : '安装已审批资源',
                  ),
                ),
                OutlinedButton(
                  onPressed: service.busy
                      ? null
                      : () async {
                          try {
                            await service.clearInactiveCache();
                          } catch (_) {}
                        },
                  child: const Text('清理未使用缓存'),
                ),
                if (service.busy)
                  TextButton(
                    onPressed: service.cancel,
                    child: const Text('暂停下载'),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              '安装期间保留当前版本。下载按清单验证 SHA-256 与大小，完成后整体启用；再次安装会复用已验证的下载。缓存可离线使用，已获知撤销的版本会立即停用。',
            ),
            const SizedBox(height: 8),
            const Text(
              '线上清单仅提供其已验证的目录、研究数量、稳定颜色和图标。成就、世界纹理帧规则、角色转换规则、实体标记和世界规则预设需要单独验证的来源，目前不包含。',
            ),
          ],
        );
      },
    );
  }
}
