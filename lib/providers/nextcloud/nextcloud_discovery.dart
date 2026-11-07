import '../../discovery_models.dart';
import '../../models.dart';

TimelineDay parseNextcloudDay(Map<String, dynamic> json) {
  final id = json['dayid'];
  final count = json['count'];
  if (id is! int || count is! int || count < 0) {
    throw const FormatException('Unsupported Memories day index.');
  }
  return TimelineDay(id, count);
}

RecognizedPerson parseNextcloudPerson(Map<String, dynamic> json) {
  final rawCover = json['cover'];
  return RecognizedPerson.fromJson({
    'id': json['id'],
    'name': json['name'],
    'count': json['count'],
    if (rawCover != null)
      'cover': rawCover is String
          ? int.tryParse(rawCover) ?? rawCover
          : rawCover,
    if (json['cover_etag'] != null) 'coverEtag': json['cover_etag'],
  });
}

double _coordinate(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) {
    final parsed = double.tryParse(value);
    if (parsed != null) return parsed;
  }
  throw const FormatException('Invalid photo location.');
}

PhotoLocation parseNextcloudLocation(Map<String, dynamic> json) =>
    PhotoLocation(_coordinate(json['lat']), _coordinate(json['lon']));

PhotoMapCluster parseNextcloudMapCluster(Map<String, dynamic> json) {
  final id = json['id'];
  final center = json['center'];
  final count = json['count'];
  final preview = json['preview'];
  if (id is! int ||
      id <= 0 ||
      center is! List ||
      center.length != 2 ||
      count is! num ||
      !count.isFinite ||
      count < 0 ||
      count != count.roundToDouble() ||
      (preview != null && preview is! Map)) {
    throw const FormatException('Unsupported photo map cluster.');
  }
  final previewId = preview is Map ? preview['fileid'] : null;
  final previewEtag = preview is Map ? preview['etag'] : null;
  if ((previewId != null && (previewId is! int || previewId <= 0)) ||
      (previewEtag != null && previewEtag is! String)) {
    throw const FormatException('Unsupported photo map preview.');
  }
  return PhotoMapCluster(
    id: id,
    location: PhotoLocation(_coordinate(center[0]), _coordinate(center[1])),
    count: count.toInt(),
    previewId: previewId as int?,
    previewEtag: previewEtag as String?,
  );
}
