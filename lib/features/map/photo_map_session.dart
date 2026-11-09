import '../../core/cloud/cloud_backend.dart';
import '../../discovery_models.dart';
import '../../models.dart';

/// Coordinates a map's requests for the account that opened it.
class PhotoMapSession {
  PhotoMapSession({
    required CloudBackend client,
    required Account account,
    required bool Function() isCurrent,
  }) : _client = client,
       _account = account,
       _isCurrent = isCurrent;

  final CloudBackend _client;
  final Account _account;
  final bool Function() _isCurrent;

  void _checkCurrent() {
    if (!_isCurrent()) {
      throw const CloudException('The account changed. Open the map again.');
    }
  }

  Future<PhotoLocation?> position() async {
    _checkCurrent();
    final result = await _client.mapPosition(_account);
    _checkCurrent();
    return result;
  }

  /// Null means the viewport was superseded while fetching.
  Future<List<PhotoMapCluster>?> clusters(
    List<PhotoMapBounds> bounds, {
    required int zoom,
    required bool Function() isCurrentViewport,
  }) async {
    _checkCurrent();
    if (bounds.isEmpty) throw const FormatException('Map bounds are required.');
    final clusters = <String, PhotoMapCluster>{};
    for (final area in bounds) {
      _checkCurrent();
      if (!isCurrentViewport()) return null;
      final result = await _client.mapClusters(
        _account,
        bounds: area,
        zoom: zoom,
      );
      _checkCurrent();
      if (!isCurrentViewport()) return null;
      for (final cluster in result) {
        clusters[cluster.id] = cluster;
      }
    }
    return clusters.values.toList();
  }
}
