class BiliFavoriteCollection {
  const BiliFavoriteCollection({
    required this.id,
    required this.name,
    required this.itemCount,
    this.coverUrl,
  });

  final String id;
  final String name;
  final int itemCount;
  final String? coverUrl;
}
