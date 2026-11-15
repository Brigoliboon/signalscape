import 'package:flutter_test/flutter_test.dart';
import 'package:signalscape_mobile/core/sync_engine.dart';

class FakeStore implements SyncStore {
  FakeStore({int readings = 0, int checkpoints = 0, String survey = 's1'}) {
    for (var i = 0; i < readings; i++) {
      _rows.add((survey, SyncKind.readings, 'r$i'));
    }
    for (var i = 0; i < checkpoints; i++) {
      _rows.add((survey, SyncKind.checkpoints, 'c$i'));
    }
  }

  final List<(String, SyncKind, String)> _rows = [];
  final Set<String> synced = {};

  @override
  Future<PendingBatch?> nextBatch(int limit) async {
    // Checkpoints first, like the real store.
    for (final kind in [SyncKind.checkpoints, SyncKind.readings]) {
      final open = _rows
          .where((r) => r.$2 == kind && !synced.contains(r.$3))
          .toList();
      if (open.isEmpty) continue;
      final survey = open.first.$1;
      final take = open.where((r) => r.$1 == survey).take(limit).toList();
      return PendingBatch(
        surveyId: survey,
        kind: kind,
        ids: [for (final r in take) r.$3],
        items: [
          for (final r in take) {'client_id': r.$3},
        ],
      );
    }
    return null;
  }

  @override
  Future<void> markSynced(PendingBatch batch) async => synced.addAll(batch.ids);

  @override
  Future<int> pendingCount({String? surveyId}) async =>
      _rows.where((r) => !synced.contains(r.$3)).length;
}

class FakeTransport implements SyncTransport {
  FakeTransport([List<SyncException?> script = const []])
    : _script = [...script];

  final List<SyncException?> _script; // null = succeed, in call order
  final List<PendingBatch> sent = [];
  int calls = 0;

  @override
  Future<void> send(PendingBatch batch) async {
    calls++;
    if (_script.isNotEmpty) {
      final next = _script.removeAt(0);
      if (next != null) throw next;
    }
    sent.add(batch);
  }
}

SyncException net() => SyncException('offline', retryable: true);

void main() {
  test('sends in batches of at most 500 and marks them synced', () async {
    final store = FakeStore(readings: 1203);
    final transport = FakeTransport();
    final result = await SyncEngine(store: store, transport: transport).pump();
    expect(result.ok, isTrue);
    expect(result.sent, 1203);
    expect(transport.sent.map((b) => b.items.length), [500, 500, 203]);
    expect(await store.pendingCount(), 0);
  });

  test('sends checkpoints before readings', () async {
    final store = FakeStore(readings: 3, checkpoints: 2);
    final transport = FakeTransport();
    await SyncEngine(store: store, transport: transport).pump();
    expect(transport.sent.map((b) => b.kind), [
      SyncKind.checkpoints,
      SyncKind.readings,
    ]);
  });

  test('a failed batch is not marked synced and is sent again', () async {
    final store = FakeStore(readings: 10);
    final transport = FakeTransport([net()]);
    final engine = SyncEngine(store: store, transport: transport);

    final first = await engine.pump();
    expect(first.ok, isFalse);
    expect(first.error!.retryable, isTrue);
    expect(await store.pendingCount(), 10);

    final second = await engine.pump();
    expect(second.ok, isTrue);
    expect(await store.pendingCount(), 0);
    expect(transport.sent.single.ids.length, 10);
  });

  test(
    'stops at the first failure and keeps what already went through',
    () async {
      final store = FakeStore(readings: 700);
      final transport = FakeTransport([null, net()]);
      final result = await SyncEngine(
        store: store,
        transport: transport,
      ).pump();
      expect(result.sent, 500);
      expect(result.ok, isFalse);
      expect(await store.pendingCount(), 200);
    },
  );

  test('an empty queue is a quiet success', () async {
    final transport = FakeTransport();
    final result = await SyncEngine(
      store: FakeStore(),
      transport: transport,
    ).pump();
    expect(result.ok, isTrue);
    expect(result.sent, 0);
    expect(transport.calls, 0);
  });

  test('two pumps at once share one run', () async {
    final store = FakeStore(readings: 5);
    final transport = FakeTransport();
    final engine = SyncEngine(store: store, transport: transport);
    final a = engine.pump();
    final b = engine.pump();
    expect(identical(a, b), isTrue);
    await a;
    expect(transport.calls, 1);
  });

  test('backoff is 5 s, 10 s, 30 s, then 2 min', () {
    expect(SyncEngine.backoffFor(0), Duration.zero);
    expect(SyncEngine.backoffFor(1), const Duration(seconds: 5));
    expect(SyncEngine.backoffFor(2), const Duration(seconds: 10));
    expect(SyncEngine.backoffFor(3), const Duration(seconds: 30));
    expect(SyncEngine.backoffFor(4), const Duration(minutes: 2));
    expect(SyncEngine.backoffFor(50), const Duration(minutes: 2));
  });

  test('flushAll retries with growing waits until it succeeds', () async {
    final waits = <Duration>[];
    final store = FakeStore(readings: 4);
    final engine = SyncEngine(
      store: store,
      transport: FakeTransport([net(), net(), net()]),
      delay: (d) async => waits.add(d),
    );
    await engine.flushAll();
    expect(waits, const [
      Duration(seconds: 5),
      Duration(seconds: 10),
      Duration(seconds: 30),
    ]);
    expect(await store.pendingCount(), 0);
  });

  test('flushAll gives up after too many failures in a row', () async {
    final engine = SyncEngine(
      store: FakeStore(readings: 1),
      transport: FakeTransport(List.filled(10, net())),
      delay: (_) async {},
    );
    await expectLater(
      engine.flushAll(maxFailures: 3),
      throwsA(isA<SyncException>()),
    );
  });

  test('flushAll does not retry an error that needs a person', () async {
    final transport = FakeTransport([
      SyncException('This survey is completed', retryable: false),
    ]);
    final engine = SyncEngine(
      store: FakeStore(readings: 1),
      transport: transport,
      delay: (_) async => fail('should not wait'),
    );
    await expectLater(engine.flushAll(), throwsA(isA<SyncException>()));
    expect(transport.calls, 1);
  });
}
