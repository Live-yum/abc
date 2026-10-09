import 'generation_schema.dart';

enum CloudCapability {
  saves,
  upload,
  download,
  generation,
  recommendations,
  profile,
  updateProfile,
}

class CloudFailure implements Exception {
  const CloudFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Only held in memory. The host supplies a supported, approved login adapter.
class CloudSession {
  const CloudSession({required this.accessToken, required this.expiresAt});
  final String accessToken;
  final DateTime expiresAt;
  bool get valid => accessToken.isNotEmpty && expiresAt.isAfter(DateTime.now());
  @override
  String toString() => 'CloudSession(redacted)';
}

abstract interface class AuthProvider {
  Future<CloudSession> signIn();
  Future<void> signOut();
}

class UnavailableAuthProvider implements AuthProvider {
  const UnavailableAuthProvider();
  @override
  Future<CloudSession> signIn() async => throw const CloudFailure(
    'Cross-platform sign-in is not configured. A supported backend identity adapter is required.',
  );
  @override
  Future<void> signOut() async {}
}

enum CloudJobStatus {
  queued,
  submitting,
  checking,
  approved,
  uploading,
  ready,
  rejected,
  failed,
  deleting,
  generationQueued,
  generating,
  generationFailed,
  uploadFailed,
  cancelling,
  cancelled,
  unknown;

  static CloudJobStatus parse(String value) => switch (value) {
    'gen_queued' => generationQueued,
    'gen_failed' => generationFailed,
    'upload_failed' => uploadFailed,
    _ => values.firstWhere((v) => v.name == value, orElse: () => unknown),
  };
  bool get terminal => {
    ready,
    rejected,
    failed,
    generationFailed,
    uploadFailed,
    cancelled,
    unknown,
  }.contains(this);
  bool get retryable => {
    failed,
    generationFailed,
    uploadFailed,
    rejected,
    cancelled,
  }.contains(this);
}

class CloudSave {
  const CloudSave({
    required this.id,
    required this.fileName,
    required this.kind,
    required this.status,
    required this.fileSize,
  });
  factory CloudSave.fromJson(Map<String, dynamic> j) => CloudSave(
    id: j['id'] as String,
    fileName: j['fileName'] as String,
    kind: j['kind'] as String,
    status: CloudJobStatus.parse(j['status'] as String),
    fileSize: j['fileSize'] as int,
  );
  final String id, fileName, kind;
  final int fileSize;
  final CloudJobStatus status;
}

class GenerationOptions {
  GenerationOptions({
    required this.enabled,
    required this.versions,
    required this.schema,
  });
  factory GenerationOptions.fromJson(Map<String, dynamic> j) =>
      GenerationOptions(
        enabled: j['enabled'] == true,
        versions: List<String>.from(j['versions'] as List),
        schema: GenerationSchema.fromJson(
          Map<String, dynamic>.from(j['schema'] as Map),
        ),
      );
  final bool enabled;
  final List<String> versions;
  final GenerationSchema schema;
}

class GenerationRequest {
  const GenerationRequest({
    required this.name,
    required this.version,
    required this.seed,
    required this.size,
    required this.difficulty,
    required this.evil,
    required this.config,
    required this.revision,
  });
  final String name, version, seed, size, difficulty, evil, revision;
  final Map<String, dynamic> config;
  Map<String, dynamic> toJson() => {
    'name': name,
    'version': version,
    'seed': seed,
    'size': size,
    'difficulty': difficulty,
    'evil': evil,
    'config': config,
    'revision': revision,
  };
}
