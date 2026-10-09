import 'generation_schema.dart';

enum CloudCapability {
  saves,
  upload,
  download,
  generation,
  recommendations,
  profile,
  updateProfile,
  help,
}

class CloudFailure implements Exception {
  const CloudFailure(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}

/// Only held in memory. The host supplies a supported, approved login adapter.
class CloudSession {
  const CloudSession({
    required this.accessToken,
    required this.expiresAt,
    this.accountId,
  });
  final String accessToken;
  final DateTime expiresAt;

  /// Stable authenticated identity supplied by the supported login adapter.
  /// Never derive this from the token, nickname, or other display fields.
  final String? accountId;
  bool get valid => accessToken.isNotEmpty && expiresAt.isAfter(DateTime.now());
  @override
  String toString() => 'CloudSession(redacted)';
}

final _cloudUuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);
String cloudUuid(String value) {
  if (!_cloudUuid.hasMatch(value)) {
    throw const CloudFailure('Invalid save or operation identifier.');
  }
  return value;
}

String cloudFileName(String value) {
  if (value.isEmpty ||
      value.length > 255 ||
      value.contains(RegExp(r'[/\\\x00-\x1f\x7f-\x9f]'))) {
    throw const CloudFailure('Invalid cloud file name.');
  }
  return value;
}

class CloudHelpArticle {
  const CloudHelpArticle({
    required this.id,
    required this.title,
    required this.content,
  });
  factory CloudHelpArticle.fromJson(Map<String, dynamic> json) {
    final title = json['title'], content = json['content'];
    if (title is! String ||
        title.length > 512 ||
        content is! String ||
        content.length > 128 * 1024) {
      throw const CloudFailure('Invalid help article.');
    }
    return CloudHelpArticle(
      id: '${json['id'] ?? ''}',
      title: title,
      content: content,
    );
  }
  final String id, title, content;
}

class CloudRecommendation {
  const CloudRecommendation({
    required this.id,
    required this.kind,
    required this.title,
    required this.description,
    required this.fileName,
    required this.fileSize,
    required this.visible,
    required this.ready,
    required this.liked,
    required this.likeCount,
    required this.downloadCount,
    this.metadata = const {},
  });
  factory CloudRecommendation.fromJson(Map<String, dynamic> json) {
    final id = cloudUuid(json['id'] as String), kind = json['kind'] as String;
    final title = json['title'] as String,
        description = json['description'] as String;
    final size = json['fileSize'] as int,
        likes = json['likeCount'] as int,
        downloads = json['downloadCount'] as int;
    if (!{'world', 'player'}.contains(kind) ||
        title.length > 512 ||
        description.length > 64 * 1024 ||
        size < 1 ||
        likes < 0 ||
        downloads < 0) {
      throw const CloudFailure('Invalid recommendation.');
    }
    return CloudRecommendation(
      id: id,
      kind: kind,
      title: title,
      description: description,
      fileName: cloudFileName(json['fileName'] as String),
      fileSize: size,
      visible: json['visible'] == true,
      ready: json['status'] == 'ready',
      liked: json['liked'] == true,
      likeCount: likes,
      downloadCount: downloads,
      metadata: Map.unmodifiable(
        Map<String, dynamic>.from(json['metadata'] as Map? ?? const {}),
      ),
    );
  }
  final String id, kind, title, description, fileName;
  final int fileSize, likeCount, downloadCount;
  final bool visible, ready, liked;
  final Map<String, dynamic> metadata;
  CloudRecommendation withCounts(CloudRecommendationCounts counts) =>
      CloudRecommendation(
        id: id,
        kind: kind,
        title: title,
        description: description,
        fileName: fileName,
        fileSize: fileSize,
        visible: visible,
        ready: ready,
        liked: counts.liked ?? liked,
        likeCount: counts.likeCount ?? likeCount,
        downloadCount: counts.downloadCount,
        metadata: metadata,
      );
  CloudSave get save => CloudSave(
    id: id,
    kind: kind,
    fileName: fileName,
    fileSize: fileSize,
    status: ready ? CloudJobStatus.ready : CloudJobStatus.unknown,
  );
}

class CloudRecommendationCounts {
  const CloudRecommendationCounts({
    required this.id,
    required this.downloadCount,
    this.likeCount,
    this.liked,
  });
  factory CloudRecommendationCounts.fromJson(Map<String, dynamic> json) {
    final result = CloudRecommendationCounts(
      id: cloudUuid(json['id'] as String),
      downloadCount: json['downloadCount'] as int,
      likeCount: json['likeCount'] as int?,
      liked: json['liked'] as bool?,
    );
    if (result.downloadCount < 0 || (result.likeCount ?? 0) < 0) {
      throw const CloudFailure('Invalid recommendation counts.');
    }
    return result;
  }
  final String id;
  final int downloadCount;
  final int? likeCount;
  final bool? liked;
}

class CloudRecommendationTicket {
  const CloudRecommendationTicket({
    required this.operationId,
    required this.downloadUrl,
    required this.fileName,
    required this.fileSize,
    required this.expiresAt,
  });
  factory CloudRecommendationTicket.fromJson(Map<String, dynamic> json) {
    final result = CloudRecommendationTicket(
      operationId: cloudUuid(json['operationId'] as String),
      downloadUrl: json['downloadUrl'] as String,
      fileName: cloudFileName(json['fileName'] as String),
      fileSize: json['fileSize'] as int,
      expiresAt: DateTime.parse(json['expiresAt'] as String),
    );
    if (result.fileSize < 1 || !result.expiresAt.isAfter(DateTime.now())) {
      throw const CloudFailure('Recommendation ticket is invalid or expired.');
    }
    return result;
  }
  final String operationId, downloadUrl, fileName;
  final int fileSize;
  final DateTime expiresAt;
}

class CloudRecommendationTransfer {
  const CloudRecommendationTransfer({
    required this.operationId,
    required this.status,
    required this.downloadCount,
    this.cloudSaveId,
  });
  factory CloudRecommendationTransfer.fromJson(Map<String, dynamic> json) {
    final result = CloudRecommendationTransfer(
      operationId: cloudUuid(json['operationId'] as String),
      status: json['status'] as String,
      downloadCount: json['downloadCount'] as int,
      cloudSaveId: json['cloudSaveId'] == null
          ? null
          : cloudUuid(json['cloudSaveId'] as String),
    );
    if (!{'pending', 'ready', 'failed'}.contains(result.status) ||
        result.downloadCount < 0) {
      throw const CloudFailure('Invalid transfer result.');
    }
    return result;
  }
  final String operationId, status;
  final int downloadCount;
  final String? cloudSaveId;
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
  factory CloudSave.fromJson(Map<String, dynamic> j) {
    final kind = j['kind'] as String, size = j['fileSize'] as int;
    if (!{'world', 'player', 'image'}.contains(kind) || size < 0) {
      throw const CloudFailure('Invalid cloud save.');
    }
    return CloudSave(
      id: cloudUuid(j['id'] as String),
      fileName: cloudFileName(j['fileName'] as String),
      kind: kind,
      status: CloudJobStatus.parse(j['status'] as String),
      fileSize: size,
    );
  }
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
