import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_tourney/server/server.dart';

/// Advertising the wrong local address produces a QR code nobody can open,
/// which is the worst way a LAN event can fail. These pin the ranking.
void main() {
  List<String> ranked(List<LanAddress> input) => [
    for (final a in rankLanAddresses(input)) a.ip,
  ];

  test('Wi-Fi beats a VPN tunnel', () {
    expect(
      ranked(const [
        LanAddress(ip: '10.8.0.6', interfaceName: 'tun0'),
        LanAddress(ip: '192.168.1.40', interfaceName: 'wlan0'),
      ]),
      ['192.168.1.40', '10.8.0.6'],
    );
  });

  test('Wi-Fi beats the cellular radio, which no player can reach', () {
    expect(
      ranked(const [
        LanAddress(ip: '10.121.3.9', interfaceName: 'rmnet_data0'),
        LanAddress(ip: '192.168.0.12', interfaceName: 'wlan0'),
      ]),
      ['192.168.0.12', '10.121.3.9'],
    );
  });

  test('a hotspot address is a real candidate', () {
    expect(
      ranked(const [LanAddress(ip: '192.168.43.1', interfaceName: 'ap0')]),
      ['192.168.43.1'],
    );
  });

  test('loopback and link-local are never offered', () {
    expect(
      ranked(const [
        LanAddress(ip: '127.0.0.1', interfaceName: 'lo'),
        LanAddress(ip: '169.254.7.7', interfaceName: 'wlan0'),
        LanAddress(ip: '192.168.1.5', interfaceName: 'wlan0'),
      ]),
      ['192.168.1.5'],
    );
  });

  test('private ranges are preferred over anything else', () {
    expect(
      ranked(const [
        LanAddress(ip: '100.64.2.3', interfaceName: 'wlan0'),
        LanAddress(ip: '172.20.1.4', interfaceName: 'wlan0'),
        LanAddress(ip: '10.0.0.4', interfaceName: 'wlan0'),
        LanAddress(ip: '192.168.1.4', interfaceName: 'wlan0'),
      ]),
      ['192.168.1.4', '10.0.0.4', '172.20.1.4', '100.64.2.3'],
    );
  });

  test('172 outside 16-31 is not a private range', () {
    expect(
      ranked(const [
        LanAddress(ip: '172.32.0.1', interfaceName: 'wlan0'),
        LanAddress(ip: '172.16.0.1', interfaceName: 'wlan0'),
      ]),
      ['172.16.0.1', '172.32.0.1'],
    );
  });

  test('a tunnel is still offered when it is all there is', () {
    expect(ranked(const [LanAddress(ip: '10.8.0.6', interfaceName: 'tun0')]), [
      '10.8.0.6',
    ]);
  });

  test('the order is stable, so a restart advertises the same address', () {
    const a = LanAddress(ip: '192.168.1.9', interfaceName: 'wlan0');
    const b = LanAddress(ip: '192.168.1.2', interfaceName: 'wlan0');
    expect(ranked(const [a, b]), ranked(const [b, a]));
  });

  test('nothing usable yields nothing', () {
    expect(
      ranked(const [LanAddress(ip: '127.0.0.1', interfaceName: 'lo')]),
      isEmpty,
    );
  });
}
