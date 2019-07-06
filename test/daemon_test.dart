import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart';
import 'package:screenshots/config.dart';
import 'package:screenshots/daemon_client.dart';
import 'package:screenshots/fastlane.dart';
import 'package:screenshots/image_processor.dart';
import 'package:screenshots/resources.dart';
import 'package:screenshots/screens.dart';
import 'package:screenshots/screenshots.dart';
import 'package:screenshots/utils.dart';
import 'package:test/test.dart';

main() {
  test('start shipped daemon client', () async {
    final flutterHome =
        dirname(dirname((cmd('which', ['flutter'], '.', true))));
    final flutterToolsHome = '$flutterHome/packages/flutter_tools';
    print('flutterToolsHome=$flutterToolsHome');
    final daemonClient = await Process.start(
        'dart', <String>['tool/daemon_client.dart'],
        workingDirectory: flutterToolsHome);
    print('shipped daemon client process started, pid: ${daemonClient.pid}');

    bool connected = false;
    bool waitingForResponse = false;
    daemonClient.stdout
        .transform<String>(utf8.decoder)
        .transform<String>(const LineSplitter())
        .listen((String line) async {
      print('<<< $line');
      if (line.contains('daemon.connected')) {
        print('connected');
        connected = true;
      }
      if (connected) {
        if (!waitingForResponse) {
          // send command
          print('get emulators');
          daemonClient.stdin.writeln('emulators');
          waitingForResponse = true;
        } else {
          // get response
          if (line.contains('result')) {
            print('emulators:$line');

            // shutdown daemon
            print('shutdown');
            daemonClient.stdin.writeln('shutdown');
          }
        }
      }
    });
    daemonClient.stderr.listen((dynamic data) => stderr.add(data));

    // wait for exit code
    print('exit code:${await daemonClient.exitCode}');
  });

  test('parse daemon response', () {
    final expected =
        '[{"id":"Nexus_5X_API_27","name":"Nexus 5X"},{"id":"Nexus_6P_API_28","name":"Nexus 6P"},{"id":"Nexus_9_API_28","name":"Nexus 9"},{"id":"apple_ios_simulator","name":"iOS Simulator"}]';
    final response = '[{"id":0,"result":$expected}]';
    final respExp = RegExp(r'result":(.*)}\]');
    final match = respExp.firstMatch(response).group(1);
    print('match=${jsonDecode(match)}');
    expect(match, expected);
  });

  test('start daemon client', () async {
    final daemonClient = DaemonClient();
    await daemonClient.start;
    print('emulators: ${await daemonClient.emulators}');
    print('devices: ${await daemonClient.devices}');
    final exitCode = await daemonClient.stop;
    print('exit code: $exitCode');
    expect(exitCode, 0);
  });

  test('launch android emulator via daemon', () async {
    final emulatorId = 'Nexus_6P_API_28';
    final name = 'Nexus 6P';
    final deviceId = 'emulator-5554';
    final daemonClient = DaemonClient();
    await daemonClient.start;
    print('starting $emulatorId...');
    daemonClient.verbose = true;
    await daemonClient.launchEmulator(emulatorId);
    daemonClient.verbose = false;
    print('$emulatorId started up');
    expect(findAndroidDeviceId(emulatorId), deviceId);
    print('emulator startup confirmed');

    // shutdown
    await shutdownAndroidEmulator(deviceId, name);
  });

  test('wait for android emulator to shutdown', () async {
    final deviceId = 'emulator-5554';
    final deviceName = 'my device';
    await waitAndroidEmulatorShutdown(deviceId, deviceName);
  });

  test('launch ios simulator', () async {
    final emulatorId = 'apple_ios_simulator';
    final daemonClient = DaemonClient();
//    daemonClient.verbose = true;
    await daemonClient.start;
    await daemonClient.launchEmulator(emulatorId);

    // shutdown
  });

  test('parse ios-deploy response', () {
    final expectedDeviceId = '3b3455019e329e007e67239d9b897148244b5053';
    final expectedModel = 'iPhone 5c (GSM)';
    final regExp = RegExp(r'Found (\w+) \(\w+, (.*), \w+, \w+\)');
    final response =
        "[....] Found $expectedDeviceId (N48AP, $expectedModel, iphoneos, armv7s) a.k.a. 'Maurice’s iPhone' connected through USB.";

    final deviceId = regExp.firstMatch(response).group(1);
    final model = regExp.firstMatch(response).group(2);
    print('deviceId=$deviceId');
    print('model=$model');
    expect(deviceId, expectedDeviceId);
    expect(model, expectedModel);
  });

  test('get ios model from device id', () {
    final deviceId = '3b3455019e329e007e67239d9b897148244b5053';
    final devices = iosDevices();
    print('devices=$devices');

    final device = devices.firstWhere((device) => device['id'] == deviceId,
        orElse: () => null);
    device == null
        ? print('device not attached')
        : print('model=${device['model']}');
  });

  test('run test on real device', () async {
    final deviceName = 'iPhone 5c';
    final testPath = 'test_driver/main.dart';
    final daemonClient = DaemonClient();
    await daemonClient.start;
    final devices = await daemonClient.devices;
    print('devices=$devices');
    final device = devices.firstWhere(
        (device) => device['model'].contains(deviceName),
        orElse: () => null);
    // clear existing screenshots from staging area
//    clearDirectory('$stagingDir/test');
    // run the test
    await streamCmd(
        'flutter', ['-d', device['id'], 'drive', testPath], 'example');
  }, timeout: Timeout(Duration(minutes: 2)));

  test('wait for start of android emulator', () async {
    final id = 'Nexus_6P_API_28';
    final name = 'Nexus 6P';
    final deviceId = 'emulator-5554';
    final daemonClient = DaemonClient();
    daemonClient.verbose = true;
    await daemonClient.start;
    daemonClient.verbose;
    await daemonClient.launchEmulator(id);

    expect(findAndroidDeviceId(id), deviceId);

    // shutdown
    await shutdownAndroidEmulator(deviceId, name);
  });

  test('join devices', () {
    final configPath = 'test/screenshots_test.yaml';
    final config = Config(configPath);
    final configInfo = config.configInfo;
    final androidInfo = configInfo['devices']['android'];
    print('androidInfo=$androidInfo');
    List deviceNames = getAllDevices(configInfo);
//    final deviceNames = []..addAll(androidDeviceNames)??[]..addAll(iosDeviceNames);
    print('deviceNames=$deviceNames');
  });

  test('run test on matching devices or emulators', () async {
    final configPath = 'test/screenshots_test.yaml';
    final screens = Screens();
    await screens.init();

    final config = Config(configPath);
    // validate config file
//    await config.validate(screens);
    final configInfo = config.configInfo;

    // init
    final stagingDir = configInfo['staging'];
    await Directory(stagingDir + '/test').create(recursive: true);
    await unpackScripts(stagingDir);
    await clearFastlaneDirs(configInfo, screens);
    final imageProcessor = ImageProcessor(screens, configInfo);

    final daemonClient = DaemonClient();
    await daemonClient.start;
    final devices = await daemonClient.devices;
    final emulators = await daemonClient.emulators;

    // for this test change directory
    final origDir = Directory.current;
    Directory.current = 'example';

    await runTestsOnAll(
        daemonClient, devices, emulators, config, screens, imageProcessor);
    // allow other tests to continue
    Directory.current = origDir;
  }, timeout: Timeout(Duration(minutes: 4)));
}