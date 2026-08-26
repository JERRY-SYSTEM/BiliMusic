class AudioQualityOption {
  const AudioQualityOption({required this.id, required this.label, required this.url, this.bandwidth = 0, this.requiresLogin = false});
  final int? id;
  final String label;
  final String url;
  final int bandwidth;
  final bool requiresLogin;
}
