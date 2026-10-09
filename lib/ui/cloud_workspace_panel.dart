import 'package:flutter/material.dart';

import '../cloud/cloud.dart';
import 'generation_options_form.dart';

/// Network operations occur only after explicit user actions. File selection and
/// local download saving are delegated to the embedding workspace.
class CloudWorkspacePanel extends StatefulWidget {
  const CloudWorkspacePanel({
    super.key,
    this.backend,
    this.onUpload,
    this.onDownload,
  });
  final CloudBackend? backend;
  final Future<void> Function()? onUpload;
  final Future<void> Function(CloudSave save)? onDownload;
  @override
  State<CloudWorkspacePanel> createState() => _CloudWorkspacePanelState();
}

class _CloudWorkspacePanelState extends State<CloudWorkspacePanel> {
  final _name = TextEditingController();
  final _seed = TextEditingController();
  String? _version;
  String _size = 'small', _difficulty = 'classic', _evil = 'random';
  Map<String, dynamic> _config = {};
  GenerationSchema? _loadedSchema;
  List<String> _errors = [];
  @override
  void dispose() {
    _name.dispose();
    _seed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final backend = widget.backend;
    if (backend == null) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('云端未连接。私有存档、推荐与世界生成需要服务配置及受支持的跨端身份；本地工具可继续使用。'),
      );
    }
    return ListenableBuilder(
      listenable: backend,
      builder: (context, _) {
        if (!backend.connected) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('云端未连接。需要受支持的登录方式；会话仅保留在内存中。'),
                OutlinedButton(
                  onPressed: backend.busy ? null : backend.signIn,
                  child: const Text('连接云端'),
                ),
                if (backend.error != null) Text(backend.error!),
              ],
            ),
          );
        }
        final options = backend.generationOptions;
        if (options != null && !identical(options.schema, _loadedSchema)) {
          _loadedSchema = options.schema;
          _config = {};
          _errors = [];
          if (!options.versions.contains(_version)) _version = null;
        }
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                const Expanded(child: Text('云端工作区')),
                TextButton(
                  onPressed: backend.signOut,
                  child: const Text('断开连接'),
                ),
              ],
            ),
            if (backend.busy) const LinearProgressIndicator(),
            if (backend.error != null)
              Text(
                backend.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (backend.supports(CloudCapability.saves))
                  OutlinedButton(
                    onPressed: backend.busy ? null : backend.refreshSaves,
                    child: const Text('刷新存档'),
                  ),
                if (backend.supports(CloudCapability.upload) &&
                    widget.onUpload != null)
                  OutlinedButton(
                    onPressed: backend.busy ? null : widget.onUpload,
                    child: const Text('选择文件上传'),
                  ),
                if (backend.supports(CloudCapability.recommendations))
                  OutlinedButton(
                    onPressed: backend.busy
                        ? null
                        : backend.loadRecommendations,
                    child: const Text('加载推荐'),
                  ),
                if (backend.supports(CloudCapability.profile))
                  OutlinedButton(
                    onPressed: backend.busy ? null : backend.loadProfile,
                    child: const Text('加载账户'),
                  ),
                if (backend.supports(CloudCapability.generation))
                  OutlinedButton(
                    onPressed: backend.busy ? null : backend.loadOptions,
                    child: const Text('加载生成选项'),
                  ),
              ],
            ),
            if (backend.account != null)
              ListTile(
                title: Text(
                  backend.account!['nickname']?.toString() ?? 'Cloud account',
                ),
                subtitle: const Text('账户资料已加载'),
                trailing: backend.supports(CloudCapability.updateProfile)
                    ? TextButton(
                        onPressed: backend.busy
                            ? null
                            : () => _editProfile(backend),
                        child: const Text('编辑昵称'),
                      )
                    : null,
              ),
            ...backend.saves.map(
              (save) => ListTile(
                title: Text(save.fileName),
                subtitle: Text(
                  '${save.kind} · ${save.status.name} · ${save.fileSize} bytes',
                ),
                trailing: Wrap(
                  children: [
                    if (save.kind == 'world' &&
                        backend.supports(CloudCapability.generation))
                      TextButton(
                        onPressed: backend.busy
                            ? null
                            : () => backend.observeJob(save),
                        child: const Text('查看进度'),
                      ),
                    if (save.status == CloudJobStatus.ready &&
                        backend.supports(CloudCapability.download) &&
                        widget.onDownload != null)
                      TextButton(
                        onPressed: backend.busy
                            ? null
                            : () => widget.onDownload!(save),
                        child: const Text('下载'),
                      ),
                  ],
                ),
              ),
            ),
            ...backend.recommended.map(
              (item) => ListTile(
                title: Text(item['title']?.toString() ?? 'Recommendation'),
                subtitle: Text(item['description']?.toString() ?? ''),
              ),
            ),
            if (backend.submissionUncertain)
              const Text(
                'Submission response was lost. 刷新存档 and select the created job before doing anything else; automatic resubmission is blocked.',
              ),
            if (backend.job case final job?)
              Card(
                child: ListTile(
                  title: Text(job.fileName),
                  subtitle: Text('Generation: ${job.status.name}'),
                  trailing: Wrap(
                    children: [
                      TextButton(
                        onPressed: backend.busy ? null : backend.refreshJob,
                        child: const Text('刷新任务'),
                      ),
                      if (!job.status.terminal)
                        TextButton(
                          onPressed: backend.busy ? null : backend.cancelJob,
                          child: const Text('取消任务'),
                        ),
                      if (job.status.retryable)
                        TextButton(
                          onPressed: backend.busy ? null : backend.retryJob,
                          child: const Text('重试任务'),
                        ),
                    ],
                  ),
                ),
              ),
            if (options != null && !options.enabled) const Text('服务端暂未启用世界生成。'),
            if (options != null && options.enabled) ...[
              TextField(
                controller: _name,
                maxLength: 128,
                decoration: const InputDecoration(labelText: 'World name'),
              ),
              TextField(
                controller: _seed,
                maxLength: 256,
                decoration: const InputDecoration(labelText: 'Seed'),
              ),
              DropdownButtonFormField<String>(
                initialValue: options.versions.contains(_version)
                    ? _version
                    : null,
                decoration: const InputDecoration(labelText: 'Version'),
                items: options.versions
                    .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                    .toList(),
                onChanged: (v) => setState(() => _version = v),
              ),
              _choice('Size', _size, [
                'small',
                'medium',
                'large',
              ], (v) => _size = v),
              _choice('Difficulty', _difficulty, [
                'classic',
                'expert',
                'master',
                'journey',
              ], (v) => _difficulty = v),
              _choice('Evil', _evil, [
                'random',
                'corruption',
                'crimson',
              ], (v) => _evil = v),
              GenerationOptionsForm(
                key: ValueKey(options.schema.revision),
                schema: options.schema,
                enabled: !backend.busy,
                onChanged: (value, errors) => setState(() {
                  _config = Map.of(value);
                  _errors = errors;
                }),
              ),
              ..._errors.take(5).map(Text.new),
              FilledButton(
                onPressed:
                    backend.busy ||
                        backend.submissionUncertain ||
                        _errors.isNotEmpty ||
                        _version == null ||
                        (backend.job != null && !backend.job!.status.terminal)
                    ? null
                    : () => backend.submitGeneration(
                        GenerationRequest(
                          name: _name.text.trim(),
                          version: _version!,
                          seed: _seed.text,
                          size: _size,
                          difficulty: _difficulty,
                          evil: _evil,
                          config: _config,
                          revision: options.schema.revision,
                        ),
                      ),
                child: const Text('提交生成任务'),
              ),
            ],
          ],
        );
      },
    );
  }

  Future<void> _editProfile(CloudBackend backend) async {
    final account = backend.account;
    final originalSession = backend.session;
    if (account == null) return;
    final controller = TextEditingController(
      text: account['nickname']?.toString() ?? '',
    );
    final nickname = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑云端昵称'),
        content: TextField(
          controller: controller,
          maxLength: 80,
          decoration: const InputDecoration(labelText: 'Nickname'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('保存到云端'),
          ),
        ],
      ),
    );
    // Let the dialog route release its text field before disposing its controller.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();
    if (!mounted ||
        nickname == null ||
        nickname.isEmpty ||
        !backend.connected ||
        !identical(originalSession, backend.session)) {
      return;
    }
    await backend.saveProfile({'id': account['id'], 'nickname': nickname});
  }

  Widget _choice(
    String label,
    String value,
    List<String> choices,
    void Function(String) onChanged,
  ) => DropdownButtonFormField<String>(
    initialValue: value,
    decoration: InputDecoration(labelText: label),
    items: choices
        .map((c) => DropdownMenuItem(value: c, child: Text(c)))
        .toList(),
    onChanged: (v) {
      if (v != null) setState(() => onChanged(v));
    },
  );
}
