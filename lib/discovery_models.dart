class RecognizedPerson {
  const RecognizedPerson({
    required this.id,
    required this.name,
    required this.count,
    this.cover,
    this.coverEtag,
  });

  final String id;
  final String name;
  final int count;
  final String? cover;
  final String? coverEtag;
  bool get named => name.trim().isNotEmpty;
  String get label => named ? name : 'Unnamed person';

  static int compareByCount(RecognizedPerson a, RecognizedPerson b) {
    final count = b.count.compareTo(a.count);
    if (count != 0) return count;
    final left = int.tryParse(a.id);
    final right = int.tryParse(b.id);
    if (left != null && right != null) {
      final numeric = left.compareTo(right);
      if (numeric != 0) return numeric;
    } else if (left != null || right != null) {
      return left != null ? -1 : 1;
    }
    return a.id.compareTo(b.id);
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'count': count,
    if (cover != null) 'cover': cover,
    if (coverEtag != null) 'coverEtag': coverEtag,
  };

  factory RecognizedPerson.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    final count = json['count'];
    final cover = json['cover'];
    final etag = json['coverEtag'];
    if (id is! String ||
        id.isEmpty ||
        name is! String ||
        count is! int ||
        count < 0 ||
        (cover != null && (cover is! String || cover.isEmpty)) ||
        (etag != null && etag is! String)) {
      throw const FormatException('Invalid person record.');
    }
    return RecognizedPerson(
      id: id,
      name: name,
      count: count,
      cover: cover as String?,
      coverEtag: etag as String?,
    );
  }
}

class PhotoLocation {
  PhotoLocation(this.latitude, this.longitude) {
    if (!latitude.isFinite ||
        latitude < -90 ||
        latitude > 90 ||
        !longitude.isFinite ||
        longitude < -180 ||
        longitude > 180) {
      throw const FormatException('Invalid photo location.');
    }
  }

  final double latitude;
  final double longitude;
}

/// Non-wrapping viewport. Split an antimeridian-crossing view into two bounds.
class PhotoMapBounds {
  PhotoMapBounds({
    required this.south,
    required this.north,
    required this.west,
    required this.east,
  }) {
    PhotoLocation(south, west);
    PhotoLocation(north, east);
    if (south > north || west > east) {
      throw const FormatException('Invalid map bounds; split wrapped views.');
    }
  }

  final double south;
  final double north;
  final double west;
  final double east;
  String get query => '$south,$north,$west,$east';

  static List<PhotoMapBounds> viewport({
    required double south,
    required double north,
    required double west,
    required double east,
  }) {
    if (![south, north, west, east].every((v) => v.isFinite) ||
        south > north ||
        south < -90 ||
        north > 90) {
      throw const FormatException('Invalid map viewport.');
    }
    var width = east - west;
    if (width < 0) width = width % 360;
    if (width >= 360) {
      return [
        PhotoMapBounds(south: south, north: north, west: -180, east: 180),
      ];
    }
    final start = (west + 180) % 360 - 180;
    final end = start + width;
    return end <= 180
        ? [PhotoMapBounds(south: south, north: north, west: start, east: end)]
        : [
            PhotoMapBounds(south: south, north: north, west: start, east: 180),
            PhotoMapBounds(
              south: south,
              north: north,
              west: -180,
              east: end - 360,
            ),
          ];
  }
}

class PhotoMapCluster {
  const PhotoMapCluster({
    required this.id,
    required this.location,
    required this.count,
    this.previewId,
    this.previewEtag,
  });

  final String id;
  final PhotoLocation location;
  final int count;
  final String? previewId;
  final String? previewEtag;
}
