class DockerContainer {
  const DockerContainer({
    required this.id,
    required this.name,
    required this.image,
    required this.state,
    required this.status,
    required this.ports,
    required this.createdAt,
  });

  final String id;
  final String name;
  final String image;
  final String state;
  final String status;
  final String ports;
  final String createdAt;

  String get shortId => id.length > 12 ? id.substring(0, 12) : id;

  factory DockerContainer.fromJson(Map<String, dynamic> json) =>
      DockerContainer(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        image: json['image'] as String? ?? '',
        state: json['state'] as String? ?? '',
        status: json['status'] as String? ?? '',
        ports: json['ports'] as String? ?? '',
        createdAt: json['created_at'] as String? ?? '',
      );
}

class DockerImage {
  const DockerImage({
    required this.id,
    required this.repository,
    required this.tag,
    required this.size,
    required this.createdAt,
  });

  final String id;
  final String repository;
  final String tag;
  final String size;
  final String createdAt;

  factory DockerImage.fromJson(Map<String, dynamic> json) => DockerImage(
    id: json['id'] as String? ?? '',
    repository: json['repository'] as String? ?? '',
    tag: json['tag'] as String? ?? '',
    size: json['size'] as String? ?? '',
    createdAt: json['created_at'] as String? ?? '',
  );
}
