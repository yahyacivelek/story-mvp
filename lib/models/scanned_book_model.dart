class ScannedBook {
  final String id;
  final String title;
  final DateTime createdAt;
  List<String> pageImagePaths;
  String? generatedStoryJsonPath;

  ScannedBook({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.pageImagePaths,
    this.generatedStoryJsonPath,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'pageImagePaths': pageImagePaths,
        'generatedStoryJsonPath': generatedStoryJsonPath,
      };

  factory ScannedBook.fromJson(Map<String, dynamic> json) => ScannedBook(
        id: json['id'] as String,
        title: json['title'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        pageImagePaths: List<String>.from(json['pageImagePaths'] as List),
        generatedStoryJsonPath: json['generatedStoryJsonPath'] as String?,
      );

  ScannedBook copyWith({
    String? id,
    String? title,
    DateTime? createdAt,
    List<String>? pageImagePaths,
    String? generatedStoryJsonPath,
  }) {
    return ScannedBook(
      id: id ?? this.id,
      title: title ?? this.title,
      createdAt: createdAt ?? this.createdAt,
      pageImagePaths: pageImagePaths ?? List<String>.from(this.pageImagePaths),
      generatedStoryJsonPath: generatedStoryJsonPath ?? this.generatedStoryJsonPath,
    );
  }
}
