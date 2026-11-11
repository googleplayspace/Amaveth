/// The version guide is independent of feature checks needed to open IM safely.
bool shouldPromptWebViewUpgrade(String? version) {
  final major = int.tryParse((version ?? '').split('.').first);
  return major != null && major > 0 && major < 92;
}
