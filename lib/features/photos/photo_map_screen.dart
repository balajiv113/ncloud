import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_controller.dart';
import '../../diagnostics.dart';
import '../../discovery_models.dart';
import '../library/media_tile.dart';
import '../../models.dart';
import '../../core/cloud/cloud_backend.dart';
import '../../core/ui/messages.dart';
import 'photo_map_session.dart';

class PhotoMapScreen extends StatefulWidget {
  const PhotoMapScreen({
    super.key,
    required this.controller,
    required this.onOpenArea,
  });

  final AppController controller;
  final ValueChanged<List<PhotoMapBounds>> onOpenArea;

  @override
  State<PhotoMapScreen> createState() => _PhotoMapScreenState();
}

class _PhotoMapScreenState extends State<PhotoMapScreen> {
  final _map = MapController();
  PhotoLocation? _position;
  List<PhotoMapCluster> _clusters = [];
  List<PhotoMapBounds> _bounds = [];
  Timer? _debounce;
  bool _initializing = true;
  bool _loading = false;
  bool _tilesEnabled = false;
  bool _tileError = false;
  String? _error;
  int _generation = 0;
  bool _fetching = false;
  bool _queued = false;
  PhotoMapSession? _session;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    _map.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    setState(() {
      _initializing = true;
      _error = null;
    });
    final controller = widget.controller;
    final session = controller.account;
    try {
      if (controller.demo) {
        setState(() => _position = null);
      } else if (session == null) {
        throw const CloudException('Sign in to browse your photo map.');
      } else {
        final mapSession = controller.photoMapSession();
        _session = mapSession;
        final position = await mapSession.position();
        if (!mounted || controller.account != session) return;
        setState(() => _position = position);
      }
    } catch (e) {
      if (mounted && identical(controller.account, session)) {
        setState(() => _error = errorMessage(e));
      }
    } finally {
      if (mounted) setState(() => _initializing = false);
    }
  }

  List<PhotoMapBounds> _visibleBounds() {
    final bounds = _map.camera.visibleBounds;
    return PhotoMapBounds.viewport(
      south: bounds.south.clamp(-90, 90).toDouble(),
      north: bounds.north.clamp(-90, 90).toDouble(),
      west: bounds.west,
      east: bounds.east,
    );
  }

  void _schedule() {
    _generation++;
    _debounce?.cancel();
    _queued = false;
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      _queued = true;
      _refresh();
    });
  }

  Future<void> _refresh() async {
    if (_fetching || !mounted) return;
    _fetching = true;
    try {
      while (_queued && mounted) {
        _queued = false;
        final generation = _generation;
        final controller = widget.controller;
        final session = controller.account;
        if (session == null) return;
        final bounds = _visibleBounds();
        final zoom = _map.camera.zoom.round().clamp(0, 22);
        setState(() {
          _loading = true;
          _error = null;
        });
        try {
          final mapSession = _session ?? controller.photoMapSession();
          _session = mapSession;
          final clusters = await mapSession.clusters(
            bounds,
            zoom: zoom,
            isCurrentViewport: () => mounted && generation == _generation,
          );
          if (clusters != null &&
              mounted &&
              generation == _generation &&
              controller.account == session) {
            setState(() {
              _clusters = clusters;
              _bounds = bounds;
            });
          }
        } catch (e) {
          if (mounted &&
              generation == _generation &&
              controller.account == session) {
            setState(() => _error = errorMessage(e));
          }
        } finally {
          if (mounted) setState(() => _loading = false);
        }
      }
    } finally {
      _fetching = false;
    }
  }

  void _retry() {
    _queued = true;
    _refresh();
  }

  void _zoom(double delta) {
    _map.move(_map.camera.center, (_map.camera.zoom + delta).clamp(1, 20));
  }

  Widget _marker(PhotoMapCluster cluster) {
    final file = cluster.previewId == null
        ? null
        : CloudFile(
            id: cluster.previewId,
            path: [CloudFile.pendingRoot, cluster.previewId!],
            name: 'Map photo',
            isDirectory: false,
            contentType: 'image/jpeg',
            etag: cluster.previewEtag,
          );
    return Semantics(
      button: true,
      label:
          '${cluster.count} photos near ${cluster.location.latitude.toStringAsFixed(2)}, ${cluster.location.longitude.toStringAsFixed(2)}',
      child: Tooltip(
        excludeFromSemantics: true,
        message: 'Zoom to ${cluster.count} photos',
        child: GestureDetector(
          onTap: () => _map.move(
            LatLng(cluster.location.latitude, cluster.location.longitude),
            (_map.camera.zoom + 2).clamp(1, 20),
          ),
          child: ExcludeSemantics(
            child: Stack(
              children: [
                Container(
                  margin: const EdgeInsets.only(right: 6, bottom: 10),
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white, width: 3),
                    boxShadow: const [
                      BoxShadow(color: Colors.black26, blurRadius: 6),
                    ],
                  ),
                  child: file == null
                      ? const Center(child: Icon(Icons.location_on_outlined))
                      : MediaTile(file: file, controller: widget.controller),
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${cluster.count}',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onPrimary,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _attribution() async {
    try {
      if (!await launchUrl(
        Uri.parse('https://www.openstreetmap.org/copyright'),
      )) {
        throw const CloudException('Could not open map attribution.');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(errorMessage(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Map')),
    body: _initializing
        ? const Center(child: CircularProgressIndicator())
        : _position == null
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: _error != null
                  ? MessageCard(
                      message: _error!,
                      isError: true,
                      onRetry: _initialize,
                    )
                  : const Text(
                      'No geotagged photos yet. Photos with saved GPS coordinates appear here.',
                    ),
            ),
          )
        : Column(
            children: [
              if (!_tilesEnabled)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Pins come from your server. Optional background tiles send the viewed map area and your IP address to OpenStreetMap, never your photos.',
                      ),
                      TextButton(
                        onPressed: () => setState(() => _tilesEnabled = true),
                        child: const Text('Load OpenStreetMap background'),
                      ),
                    ],
                  ),
                ),
              if (_error case final error?)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: MessageCard(
                    message: error,
                    isError: true,
                    onRetry: _retry,
                  ),
                ),
              if (_tileError)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text(
                    'Map background unavailable. Your photo pins still work.',
                  ),
                ),
              Expanded(
                child: Stack(
                  children: [
                    FlutterMap(
                      mapController: _map,
                      options: MapOptions(
                        initialCenter: LatLng(
                          _position!.latitude,
                          _position!.longitude,
                        ),
                        initialZoom: 5,
                        minZoom: 1,
                        maxZoom: 20,
                        onMapReady: _schedule,
                        onPositionChanged: (_, _) => _schedule(),
                        interactionOptions: const InteractionOptions(
                          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                        ),
                      ),
                      children: [
                        if (_tilesEnabled)
                          TileLayer(
                            urlTemplate:
                                'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                            userAgentPackageName: 'ncloud',
                            maxNativeZoom: 19,
                            errorTileCallback: (_, _, _) {
                              if (mounted && !_tileError) {
                                WidgetsBinding.instance.addPostFrameCallback((
                                  _,
                                ) {
                                  if (mounted) {
                                    setState(() => _tileError = true);
                                  }
                                });
                              }
                            },
                          ),
                        MarkerLayer(
                          markers: [
                            for (final cluster in _clusters)
                              Marker(
                                point: LatLng(
                                  cluster.location.latitude,
                                  cluster.location.longitude,
                                ),
                                width: 66,
                                height: 72,
                                child: _marker(cluster),
                              ),
                          ],
                        ),
                      ],
                    ),
                    Positioned(
                      left: 12,
                      top: 12,
                      child: Chip(
                        label: Text(
                          _loading
                              ? 'Updating photo pins...'
                              : _clusters.isEmpty && _error == null
                              ? 'No photos in this area'
                              : 'All geotagged photos',
                        ),
                      ),
                    ),
                    Positioned(
                      right: 12,
                      bottom: 40,
                      child: Card(
                        child: Column(
                          children: [
                            IconButton(
                              tooltip: 'Zoom in',
                              onPressed: () => _zoom(1),
                              icon: const Icon(Icons.add),
                            ),
                            IconButton(
                              tooltip: 'Zoom out',
                              onPressed: () => _zoom(-1),
                              icon: const Icon(Icons.remove),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_tilesEnabled)
                      Positioned(
                        left: 0,
                        bottom: 0,
                        child: Material(
                          child: TextButton(
                            onPressed: _attribution,
                            child: const Text('© OpenStreetMap contributors'),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: FilledButton.icon(
                    onPressed: _bounds.isEmpty || _loading || _error != null
                        ? null
                        : () => widget.onOpenArea(_visibleBounds()),
                    icon: const Icon(Icons.grid_view),
                    label: const Text('Open photos in this area'),
                  ),
                ),
              ),
            ],
          ),
  );
}
