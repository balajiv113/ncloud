import '../../core/cloud/cloud_backend.dart';
import '../../core/storage/local_cache.dart';
import '../../core/storage/media_listing.dart';
import '../../models.dart';
import 'day_batches.dart';
import 'view_query.dart';

/// Fetches what a view still lacks: the next unloaded days of an indexed view
/// or the next page of one without an index. Days of the main Timeline come
/// from the on-device cache when it is complete and fresh.
///
/// It never changes a listing; the caller merges the result only if the view
/// it was fetched for is still the one shown.
class TimelineFetcher {
  TimelineFetcher({
    required this.client,
    required this.cache,
    required this.staleBefore,
  });

  final CloudBackend client;
  final LocalCache? cache;

  /// Files cached before this moment must be fetched again.
  final DateTime Function() staleBefore;

  Future<FetchedPage> next(
    MediaListing listing,
    Account session,
    ViewQuery query,
    String storeKey,
  ) async {
    final days = listing.days;
    if (days == null) return _page(listing, session, query);
    final ids = chooseDayBatch([
      for (final day in days)
        if (!listing.loaded.contains(day.id)) day,
    ], limit: query.dayBatchLimit);
    if (ids.isEmpty) return const FetchedPage([]);
    return fetchDays(listing, session, query, ids, storeKey);
  }

  Future<FetchedPage> fetchDays(
    MediaListing listing,
    Account session,
    ViewQuery query,
    List<int> ids,
    String storeKey,
  ) async {
    final files =
        await _cached(listing, query, ids, storeKey) ??
        (await client.timeline(session, query.days(ids)))!.items!;
    return FetchedPage(files, days: ids);
  }

  Future<FetchedPage> _page(
    MediaListing listing,
    Account session,
    ViewQuery query,
  ) async {
    final page = (await client.timeline(session, query.page(listing.cursor)))!;
    final repeated =
        page.nextCursor != null && page.nextCursor == listing.cursor;
    final known = listing.keys.toSet();
    final replay =
        page.items!.isNotEmpty &&
        page.items!.every((f) => known.contains(f.key));
    if (repeated || replay) {
      throw const CloudException(
        'The server repeated a page. Pull to refresh your library.',
      );
    }
    return FetchedPage(page.items!, nextCursor: page.nextCursor);
  }

  Future<List<CloudFile>?> _cached(
    MediaListing listing,
    ViewQuery query,
    List<int> ids,
    String storeKey,
  ) async {
    final since = staleBefore();
    if (cache == null ||
        !query.isMainTimeline ||
        !listing.allowCachedDays ||
        listing.updated.isBefore(since) ||
        ids.any(listing.staleDays.contains)) {
      return null;
    }
    final saved = await cache!.readDayFiles(storeKey, ids, freshSince: since);
    final counts = <int, int>{};
    for (final file in saved) {
      if (file.captureDay case final day?) {
        counts[day] = (counts[day] ?? 0) + 1;
      }
    }
    final expected = {for (final day in listing.days!) day.id: day.count};
    return ids.every((day) => counts[day] == expected[day]) ? saved : null;
  }
}
