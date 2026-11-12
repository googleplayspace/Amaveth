// Baseline: DataVerna 71e141c; project imports and channel adapted.
import 'package:Amaveth/shell/remote_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('FaceConfig.parse', () {
    test('200 with url opens B and keeps privacy/terms', () {
      final c = FaceConfig.parse(
        200,
        '{"code":200,"data":{"h5url":"https://example.com/h5",'
        '"privacy_url":"https://p.example","terms_url":""},"msg":"操作成功"}',
      );
      expect(c.verdict, ConfigVerdict.b);
      expect(c.url, 'https://example.com/h5');
      expect(c.privacyUrl, 'https://p.example');
      expect(c.termsUrl, '');
    });
    test('spec 2.1: the B url is kept byte for byte, channelcode included', () {
      for (final url in [
        'https://Web.Example.com/h5/?channelcode=ch001&a=%7e1',
        'https://example.com/?ChannelCode=ch002&channelCode=ch003',
        'https://example.com/?CHANNELCODE=',
        'https://example.com/h5',
      ]) {
        final c = FaceConfig.parse(200, '{"code":200,"data":{"h5url":"$url"}}');
        expect(c.verdict, ConfigVerdict.b, reason: url);
        expect(c.url, url, reason: url);
      }
    });
    test('404 stays on A', () {
      expect(
        FaceConfig.parse(404, '{"code":404,"data":null}').verdict,
        ConfigVerdict.a,
      );
      expect(FaceConfig.parse(404, '').verdict, ConfigVerdict.a);
    });
    test('invalid 200 response does not disable a cached B', () {
      for (final body in [
        '{"code":200,"data":null}',
        '{"code":200,"data":{"h5url":""}}',
        '{"code":200,"data":{"h5url":"http://example.com"}}',
      ]) {
        expect(
          FaceConfig.parse(200, body).verdict,
          ConfigVerdict.unknown,
          reason: body,
        );
      }
    });
    test('top-level h5url accepted; legacy data.url and whitespace are not rewritten', () {
      expect(
        FaceConfig.parse(
          200,
          '{"h5url":"https://example.test/?ChannelCode=a%2Bb"}',
        ).url,
        'https://example.test/?ChannelCode=a%2Bb',
      );
      for (final body in [
        '{"data":{"url":"https://example.test"}}',
        '{"h5url":" https://example.test "}',
        '{"h5url":"https://user:pass@example.test"}',
      ]) {
        expect(FaceConfig.parse(200, body).verdict, ConfigVerdict.unknown);
      }
    });
    test('5xx or malformed body proves nothing', () {
      expect(FaceConfig.parse(500, '').verdict, ConfigVerdict.unknown);
      expect(FaceConfig.parse(200, '<html>').verdict, ConfigVerdict.unknown);
    });
  });

  group('RemoteConfig.resolve', () {
    tearDown(() => RemoteConfig.fetchOverride = null);
    const b = FaceConfig(ConfigVerdict.b, url: 'https://example.com/h5');

    test(
      'B result is remembered, then used when the server is unreachable',
      () async {
        SharedPreferences.setMockInitialValues({});
        RemoteConfig.fetchOverride = () async => b;
        expect((await RemoteConfig.resolve(retries: [])).url, b.url);
        RemoteConfig.fetchOverride = () async => FaceConfig.unknown;
        final offline = await RemoteConfig.resolve(retries: []);
        expect(offline.verdict, ConfigVerdict.b);
        expect(offline.url, b.url);
      },
    );
    test('404 clears the remembered URL', () async {
      SharedPreferences.setMockInitialValues({RemoteConfig.cacheKey: b.url});
      RemoteConfig.fetchOverride = () async => FaceConfig.a;
      expect(
        (await RemoteConfig.resolve(retries: [])).verdict,
        ConfigVerdict.a,
      );
      RemoteConfig.fetchOverride = () async => FaceConfig.unknown;
      expect(
        (await RemoteConfig.resolve(retries: [])).verdict,
        ConfigVerdict.a,
      );
    });
    test('unreachable on first install stays on A after retries', () async {
      SharedPreferences.setMockInitialValues({});
      var calls = 0;
      RemoteConfig.fetchOverride = () async {
        calls++;
        return FaceConfig.unknown;
      };
      final r = await RemoteConfig.resolve(
        retries: [Duration.zero, Duration.zero],
      );
      expect(r.verdict, ConfigVerdict.a);
      expect(calls, 3);
    });
  });

  test('cached URL drives the next cold start until a 404 clears it', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await RemoteConfig.cachedUrl(), isNull);
    SharedPreferences.setMockInitialValues({
      RemoteConfig.cacheKey: 'https://example.com/h5',
    });
    expect(await RemoteConfig.cachedUrl(), 'https://example.com/h5');
    RemoteConfig.fetchOverride = () async => FaceConfig.a;
    await RemoteConfig.resolve(retries: []);
    RemoteConfig.fetchOverride = null;
    expect(await RemoteConfig.cachedUrl(), isNull);
  });
}
