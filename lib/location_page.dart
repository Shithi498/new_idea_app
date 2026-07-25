import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map/flutter_map.dart' as ll;
import 'package:geocoding/geocoding.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:location/location.dart' as loc;
import 'package:share_plus/share_plus.dart';

class GeocodingDistanceCalculatorPage extends StatefulWidget {
  const GeocodingDistanceCalculatorPage({super.key});

  @override
  State<GeocodingDistanceCalculatorPage> createState() =>
      _GeocodingDistanceCalculatorPageState();
}

class _GeocodingDistanceCalculatorPageState
    extends State<GeocodingDistanceCalculatorPage> {
  // GPS
  final loc.Location _location = loc.Location();

  // Map
  final MapController _mapController = MapController();

  // Start / End
  ll.LatLng? _startLocation;
  ll.LatLng? _endLocation;

  // Addresses
  String? _startAddress;
  String? _endAddress;

  // Distance
  double? _distanceInMeters;
  final ll.Distance distance = const ll.Distance();

  // UI state
  String _locationStatus = 'Initializing...';
 // bool _isLoading = false;
  bool _isLoading = 12;

  // Fallback center (Dhaka)
  final ll.LatLng _fallbackCenter = const ll.LatLng(23.780573, 90.279239);
  StreamSubscription<loc.LocationData>? _locationSub;
  @override
  void initState() {
    super.initState();
    _checkLocationAndPermission();
    _listenLiveLocation();
  }

  void _listenLiveLocation() {
    _locationSub =
        _location.onLocationChanged.listen((loc.LocationData data) async {
      if (data.latitude != null && data.longitude != null) {
        final point = ll.LatLng(data.latitude!, data.longitude!);
        final addr = await _getAddressFromLatLng(point);

        setState(() {
          _startLocation = point;
          _startAddress = addr;
          _locationStatus = "Live location updated";
        });

        _calculateDistance();

        _moveToCenter(point, 15);
      }
    });
  }

  @override
  void dispose() {
    _locationSub?.cancel();
    super.dispose();
  }

  // ---------- Geocoding helpers ----------
  Future<String> _getAddressFromLatLng(ll.LatLng point) async {
    try {
      final placemarks =
          await placemarkFromCoordinates(point.latitude, point.longitude);
      if (placemarks.isNotEmpty) {
        final p = placemarks.first;
        final parts = <String>[
          if ((p.street ?? '').isNotEmpty) p.street!,
          if ((p.locality ?? '').isNotEmpty)
            p.locality!
          else if ((p.subLocality ?? '').isNotEmpty)
            p.subLocality!,
          if ((p.country ?? '').isNotEmpty) p.country!,
        ];
        return parts.join(', ');
      }
      return '(${point.latitude.toStringAsFixed(4)}, ${point.longitude.toStringAsFixed(4)})';
    } catch (_) {
      return '(${point.latitude.toStringAsFixed(4)}, ${point.longitude.toStringAsFixed(4)})';
    }
  }

  Future<List<(String, ll.LatLng)>> _forwardGeocode(String query) async {
    final results = await locationFromAddress(query);
    final limited = results.take(5).toList();
    final List<(String, ll.LatLng)> items = [];
    for (final r in limited) {
      final point = ll.LatLng(r.latitude, r.longitude);
      final nice = await _getAddressFromLatLng(point);
      items.add((nice, point));
    }
    return items;
  }

  Future<void> _checkLocationAndPermission() async {
    setState(() => _locationStatus = 'Checking permissions and services...');

    bool serviceEnabled = await _location.serviceEnabled();
    if (!serviceEnabled) {
      serviceEnabled = await _location.requestService();
      if (!serviceEnabled) {
        setState(() => _locationStatus =
            'Location Service is disabled. Please enable it.');
        return;
      }
    }

    loc.PermissionStatus permissionGranted = await _location.hasPermission();
    if (permissionGranted == loc.PermissionStatus.denied) {
      permissionGranted = await _location.requestPermission();
      if (permissionGranted != loc.PermissionStatus.granted) {
        setState(() => _locationStatus = 'Location Permission is denied.');
        return;
      }
    }

    setState(
        () => _locationStatus = 'Ready. Tap the button to set Start Location.');
    _listenLiveLocation();
  }

  Future<void> _getStartLocation() async {
    setState(() {
      _isLoading = true;
      _locationStatus = 'Fetching current GPS and resolving address...';
      _startAddress = null;
      _distanceInMeters = null;
    });

    try {
      await _checkLocationAndPermission();
      if (_locationStatus.contains('disabled') ||
          _locationStatus.contains('denied')) return;

      final loc.LocationData data = await _location.getLocation();
      if (data.latitude != null && data.longitude != null) {
        final point = ll.LatLng(data.latitude!, data.longitude!);
        final addr = await _getAddressFromLatLng(point);
        setState(() {
          _startLocation = point;
          _startAddress = addr;
          _locationStatus = 'Start Location set.';
        });
        _moveToCenter(point, 15);
        _calculateDistance();
      }
    } catch (e) {
      setState(() {
        _locationStatus = 'Error: $e';
        _startLocation = null;
        _startAddress = null;
      });
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // ---------- Share ----------
  Future<void> _shareTrip() async {
    if (_startLocation == null || _endLocation == null) return;

    final s = _startLocation!;
    final e = _endLocation!;

    // Google Maps directions URL
    final gmaps = 'https://www.google.com/maps/dir/?api=1'
        '&origin=${s.latitude},${s.longitude}'
        '&destination=${e.latitude},${e.longitude}'
        '&travelmode=driving';

    // OpenStreetMap directions URL
    final osm =
        'https://www.openstreetmap.org/directions?engine=fossgis_osrm_car'
        '&route=${s.latitude},${s.longitude};${e.latitude},${e.longitude}';

    final distanceText = _formatDistance(_distanceInMeters);
    final startText = _startAddress ??
        '(${s.latitude.toStringAsFixed(5)}, ${s.longitude.toStringAsFixed(5)})';
    final endText = _endAddress ??
        '(${e.latitude.toStringAsFixed(5)}, ${e.longitude.toStringAsFixed(5)})';

    final message = StringBuffer()
      ..writeln('📍 Trip details')
      ..writeln('From: $startText')
      ..writeln('To:   $endText')
      ..writeln('Distance: $distanceText')
      ..writeln()
      ..writeln('Google Maps: $gmaps')
      ..writeln('OpenStreetMap: $osm');

    await Share.share(message.toString(), subject: 'My trip route');
  }

  // ---------- Map interaction ----------
  void _handleMapTap(ll.TapPosition _, ll.LatLng tappedPoint) async {
    final addr = await _getAddressFromLatLng(tappedPoint);
    setState(() {
      _endLocation = tappedPoint;
      _endAddress = addr;
      _locationStatus = 'End Location set by tap.';
    });
    _calculateDistance();
  }

  // Search dialog → pick end point by typing
  Future<void> _openSearchEndDialog() async {
    final controller = TextEditingController();
    List<(String, ll.LatLng)> results = [];
    bool searching = false;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            Future<void> doSearch() async {
              final q = controller.text.trim();
              if (q.isEmpty) return;
              setModalState(() => searching = true);
              try {
                final r = await _forwardGeocode(q);
                setModalState(() => results = r);
              } catch (e) {
                setModalState(() => results = []);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('No results for “$q”')),
                );
              } finally {
                setModalState(() => searching = false);
              }
            }

            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                bottom: MediaQuery.of(context).viewInsets.bottom + 16,
                top: 8,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: controller,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText:
                          'Search destination (e.g., Bashundhara City, Dhaka)',
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    onSubmitted: (_) => doSearch(),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 280,
                    child: searching
                        ? const Center(child: CircularProgressIndicator())
                        : results.isEmpty
                            ? const Center(
                                child:
                                    Text('Type a place name and press search'))
                            : ListView.separated(
                                itemCount: results.length,
                                separatorBuilder: (_, __) =>
                                    const Divider(height: 1),
                                itemBuilder: (_, i) {
                                  final (label, point) = results[i];
                                  return ListTile(
                                    leading: const Icon(Icons.place),
                                    title: Text(label,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis),
                                    subtitle: Text(
                                      '${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)}',
                                    ),
                                    onTap: () async {
                                      final addr =
                                          await _getAddressFromLatLng(point);
                                      setState(() {
                                        _endLocation = point;
                                        _endAddress = addr;
                                        _locationStatus =
                                            'End Location set by search.';
                                      });
                                      _calculateDistance();
                                      _moveToCenter(point, 15);
                                      if (context.mounted)
                                        Navigator.pop(context);
                                    },
                                  );
                                },
                              ),
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    onPressed: searching ? null : doSearch,
                    icon: const Icon(Icons.search),
                    label: const Text('Search'),
                  ),
                  const SizedBox(height: 6),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // ---------- Calc & map camera ----------
  void _calculateDistance() {
    if (_startLocation != null && _endLocation != null) {
      final d = distance(_startLocation!, _endLocation!);
      setState(() {
        _distanceInMeters = d;
      });
    } else {
      setState(() => _distanceInMeters = null);
    }
  }

  String _formatDistance(double? meters) {
    if (meters == null) return '—';
    if (meters < 1000) return '${meters.toStringAsFixed(1)} meters';
    return '${(meters / 1000).toStringAsFixed(2)} kilometers';
  }

  ll.LatLng get _mapCenter => _startLocation ?? _fallbackCenter;

  void _moveToCenter(ll.LatLng center, double zoom) =>
      _mapController.move(center, zoom);

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    final canShare = _startLocation != null && _endLocation != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Add location'),
        backgroundColor: Colors.indigo,
        actions: [
          IconButton(
            tooltip: canShare ? 'Share trip' : 'Select both locations to share',
            onPressed: canShare ? _shareTrip : null,
            icon: const Icon(Icons.ios_share),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Info
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
            child: Column(
              children: [
                _buildInfoCard(),
                const SizedBox(height: 12),
                Text(
                  _locationStatus,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 15,
                      fontStyle: FontStyle.italic,
                      color: Colors.black54),
                ),
              ],
            ),
          ),

          // Map
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _mapCenter,
                    initialZoom: 12,
                    onTap: _handleMapTap,
                    interactionOptions: const InteractionOptions(
                      flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                    ),
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                      subdomains: const ['a', 'b', 'c'],
                      userAgentPackageName:
                          'com.kendroo.gpslocator', // must match app id
                    ),
                    MarkerLayer(
                      markers: [
                        if (_startLocation != null)
                          Marker(
                            point: _startLocation!,
                            width: 60,
                            height: 60,
                            alignment: Alignment.topCenter,
                            child: const Icon(Icons.my_location,
                                size: 40, color: Colors.indigo),
                          ),
                        if (_endLocation != null)
                          Marker(
                            point: _endLocation!,
                            width: 60,
                            height: 60,
                            alignment: Alignment.topCenter,
                            child: const Icon(Icons.place,
                                size: 40, color: Colors.red),
                          ),
                      ],
                    ),
                    if (_startLocation != null && _endLocation != null)
                      PolylineLayer(
                        polylines: [
                          ll.Polyline(
                            points: [_startLocation!, _endLocation!],
                            color: Colors.indigo,
                            strokeWidth: 4.0,
                            pattern: const StrokePattern.dotted(),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),

          // Bottom actions
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isLoading ? null : _getStartLocation,
                    icon: _isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                color: Colors.white, strokeWidth: 2),
                          )
                        : const Icon(Icons.location_searching),
                    label: const Text('SET START (CURRENT)'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.indigo,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      textStyle: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.bold),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: canShare ? _shareTrip : null,
                    icon: const Icon(Icons.ios_share),
                    label: const Text('SHARE TRIP'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                          canShare ? Colors.green.shade700 : Colors.grey,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      textStyle: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.bold),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Info card
  Widget _buildInfoCard() {
    final distanceText = _formatDistance(_distanceInMeters);
    Color distanceColor = _distanceInMeters != null
        ? Colors.indigo
        : (_startLocation != null ? Colors.orange.shade700 : Colors.grey);

    return Card(
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(18.0),
        child: Column(
          children: [
            _buildLocationDetail('Start Location:', _startAddress,
                Icons.location_searching, Colors.indigo),
            const Divider(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _buildLocationDetail(
                      'End Location:', _endAddress, Icons.place, Colors.red),
                ),
                IconButton(
                  tooltip: 'Search destination',
                  icon: const Icon(Icons.search),
                  onPressed: _openSearchEndDialog,
                ),
              ],
            ),
            const Divider(height: 20),
            // Row(
            //   mainAxisAlignment: MainAxisAlignment.spaceBetween,
            //   children: [
            //     const Text('Calculated Distance:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            //     Flexible(
            //       child: Text(
            //         distanceText,
            //         textAlign: TextAlign.right,
            //         style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: distanceColor),
            //       ),
            //     ),
            //   ],
            // ),
          ],
        ),
      ),
    );
  }

  // Detail row
  Widget _buildLocationDetail(
      String label, String? address, IconData icon, Color iconColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Icon(icon, size: 20, color: iconColor),
          const SizedBox(width: 8),
          Text(label,
              style:
                  const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        ]),
        Padding(
          padding: const EdgeInsets.only(left: 28.0, top: 4.0),
          child: Text(
            address ?? 'Awaiting GPS or destination…',
            style: TextStyle(
              fontSize: 15,
              fontStyle: address == null ? FontStyle.italic : FontStyle.normal,
              color: address == null ? Colors.grey.shade600 : Colors.black87,
            ),
          ),
        ),
      ],
    );
  }
}
