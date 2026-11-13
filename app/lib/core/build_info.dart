const String buildVersion = String.fromEnvironment(
  'HAMPANEL_VERSION',
  defaultValue: '0.1.0',
);

const String buildCommit = String.fromEnvironment(
  'HAMPANEL_COMMIT',
  defaultValue: 'unknown',
);

const String buildDirty = String.fromEnvironment(
  'HAMPANEL_DIRTY',
  defaultValue: '',
);

String get fullClientVersion {
  if (buildCommit == 'unknown' || buildCommit.isEmpty) return buildVersion;
  final suffix = buildDirty == '1' ? '.dirty' : '';
  return '$buildVersion+$buildCommit$suffix';
}
