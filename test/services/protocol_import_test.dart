import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:swock/models/vpn_profile.dart';
import 'package:swock/services/sock_uri_service.dart';

void main() {
  test('proxy share links keep their own protocol identity', () {
    final vmess = base64.encode(utf8.encode(jsonEncode({
      'ps': 'VMess test',
      'add': 'vmess.example',
      'port': '443',
      'id': '00000000-0000-0000-0000-000000000001',
    })));
    final profiles = <String, VpnProtocol>{
      'vless://00000000-0000-0000-0000-000000000001@vless.example:443':
          VpnProtocol.vless,
      'vmess://$vmess': VpnProtocol.vmess,
      'trojan://secret@trojan.example:443': VpnProtocol.trojan,
      'ss://aes-128-gcm:secret@ss.example:8388': VpnProtocol.shadowsocks,
      'hysteria2://secret@hy2.example:443': VpnProtocol.hysteria2,
      'socks://socks.example:1080': VpnProtocol.socks,
      'http://http.example:8080': VpnProtocol.http,
    };

    for (final entry in profiles.entries) {
      expect(
        SwockUriService.importUri(entry.key).protocol,
        entry.value,
        reason: entry.key,
      );
    }

    expect(
      () => SwockUriService.importUri('swock://legacy.example'),
      throwsA(isA<FormatException>()),
    );
  });

  test('custom ports are preserved, including TLS on port 80', () {
    final vless = SwockUriService.importUri(
      'vless://00000000-0000-0000-0000-000000000001@vless.example:80?security=tls&type=ws',
    );
    final trojan = SwockUriService.importUri(
      'trojan://secret@trojan.example:2053?security=tls',
    );
    final shadowsocks = SwockUriService.importUri(
      'ss://aes-128-gcm:secret@ss.example:2096?security=tls&type=ws',
    );
    final ssh = SwockUriService.importUri('ssh://user:secret@ssh.example:2222');

    expect(vless.port, 80);
    expect(trojan.port, 2053);
    expect(shadowsocks.port, 2096);
    expect(ssh.port, 2222);
  });

  test('VLESS links honor TCP, TLS, and non-WebSocket transports', () {
    final defaultTransport = SwockUriService.importUri(
      'vless://00000000-0000-0000-0000-000000000001@vless.example:443',
    );
    final grpc = SwockUriService.importUri(
      'vless://00000000-0000-0000-0000-000000000001@vless.example:443?type=grpc&security=tls&serviceName=tunnel',
    );

    expect(defaultTransport.transport, TransportMode.tcp);
    expect(defaultTransport.webSocket.enabled, isFalse);
    expect(defaultTransport.webSocket.path, isEmpty);
    expect(defaultTransport.tls.enabled, isFalse);
    expect(grpc.transport, TransportMode.grpc);
    expect(grpc.webSocket.enabled, isFalse);
    expect(grpc.tls.enabled, isTrue);
    expect(grpc.webSocket.path, 'tunnel');
    expect(grpc.xrayShareLink, contains('type=grpc'));
  });

  test('share links retain each supported Xray transport', () {
    const transports = <String, TransportMode>{
      'tcp': TransportMode.tcp,
      'kcp': TransportMode.kcp,
      'ws': TransportMode.websocketTls,
      'httpupgrade': TransportMode.httpUpgrade,
      'http': TransportMode.http,
      'quic': TransportMode.quic,
      'grpc': TransportMode.grpc,
      'xhttp': TransportMode.xhttp,
    };

    for (final entry in transports.entries) {
      final profile = SwockUriService.importUri(
        'vless://00000000-0000-0000-0000-000000000001@vless.example:443'
        '?type=${entry.key}&security=tls',
      );
      expect(profile.transport, entry.value, reason: entry.key);
      expect(profile.webSocket.path, isEmpty, reason: entry.key);
    }
  });

  test('Xray JSON import detects supported networks and transport fields', () {
    const transports = <String, TransportMode>{
      'tcp': TransportMode.tcp,
      'kcp': TransportMode.kcp,
      'ws': TransportMode.websocketTls,
      'httpupgrade': TransportMode.httpUpgrade,
      'http': TransportMode.http,
      'quic': TransportMode.quic,
      'grpc': TransportMode.grpc,
      'xhttp': TransportMode.xhttp,
      'splithttp': TransportMode.xhttp,
    };

    for (final entry in transports.entries) {
      final settings = switch (entry.key) {
        'ws' => {
            'wsSettings': {'path': '/socket'}
          },
        'httpupgrade' => {
            'httpupgradeSettings': {'path': '/upgrade', 'host': 'cdn.example'}
          },
        'http' => {
            'httpSettings': {
              'path': '/h2',
              'host': ['cdn.example']
            }
          },
        'grpc' => {
            'grpcSettings': {'serviceName': 'tunnel'}
          },
        'xhttp' || 'splithttp' => {
            'xhttpSettings': {'path': '/xhttp', 'mode': 'packet-up'}
          },
        _ => <String, dynamic>{},
      };
      final profile = SwockUriService.importUri(jsonEncode({
        'outbounds': [
          {
            'protocol': 'vless',
            'settings': {
              'vnext': [
                {
                  'address': 'vless.example',
                  'port': 443,
                  'users': [
                    {'id': '00000000-0000-0000-0000-000000000001'}
                  ],
                },
              ],
            },
            'streamSettings': {
              'network': entry.key,
              'security': 'tls',
              'tlsSettings': {'serverName': 'cdn.example'},
              ...settings,
            },
          },
        ],
      }));

      expect(profile.transport, entry.value, reason: entry.key);
      if (entry.key == 'tcp' || entry.key == 'kcp' || entry.key == 'quic') {
        expect(profile.webSocket.path, isEmpty, reason: entry.key);
      }
      if (entry.key == 'grpc') {
        expect(profile.webSocket.path, 'tunnel');
      } else if (entry.key == 'httpupgrade') {
        expect(profile.webSocket.host, 'cdn.example');
        expect(profile.webSocket.path, '/upgrade');
      } else if (entry.key == 'http') {
        expect(profile.webSocket.host, 'cdn.example');
        expect(profile.webSocket.path, '/h2');
      } else if (entry.key == 'xhttp') {
        expect(profile.webSocket.path, '/xhttp');
        expect(profile.webSocket.connectionOptions['mode'], 'packet-up');
      }
    }
  });

  test('an unspecified transport path stays empty', () {
    expect(const WebSocketConfig().path, isEmpty);
    expect(WebSocketConfig.fromJson(const {}).path, isEmpty);
  });

  test('legacy VMess links without a network default to TCP', () {
    final encoded = base64.encode(utf8.encode(jsonEncode({
      'ps': 'VMess TCP',
      'add': 'vmess.example',
      'port': '443',
      'id': '00000000-0000-0000-0000-000000000001',
      'tls': 'tls',
    })));
    final profile = SwockUriService.importUri('vmess://$encoded');

    expect(profile.transport, TransportMode.tcp);
    expect(profile.webSocket.enabled, isFalse);
    expect(profile.tls.enabled, isTrue);
  });

  test('legacy Shadowsocks links keep their encoded endpoint port', () {
    final encoded = base64Url
        .encode(utf8.encode('aes-128-gcm:secret@ss.example:23000'))
        .replaceAll('=', '');
    final profile = SwockUriService.importUri('ss://$encoded');

    expect(profile.server, 'ss.example');
    expect(profile.port, 23000);
    expect(profile.cipher, 'aes-128-gcm');
    expect(profile.password, 'secret');
  });

  test('proxy share links without a server port are rejected', () {
    final vmess = base64.encode(utf8.encode(jsonEncode({
      'ps': 'VMess test',
      'add': 'vmess.example',
      'id': '00000000-0000-0000-0000-000000000001',
    })));
    final links = [
      'vless://00000000-0000-0000-0000-000000000001@vless.example',
      'vmess://$vmess',
      'trojan://secret@trojan.example',
      'ss://aes-128-gcm:secret@ss.example',
      'ssh://user:secret@ssh.example',
      'socks://socks.example',
    ];

    for (final link in links) {
      expect(
        () => SwockUriService.importUri(link),
        throwsA(isA<FormatException>()),
        reason: link,
      );
    }
  });

  test('SSH URIs remain distinct from proxy protocols', () {
    final ssh = SwockUriService.importUri('ssh://user:secret@ssh.example:22');

    expect(ssh.protocol, VpnProtocol.ssh);
    expect(ssh.port, 22);
  });

  test('legacy native Swock profiles migrate to the Xray JSON editor', () {
    final profile = VpnProfile.fromJson({
      'id': 'legacy-swock',
      'name': 'Old tunnel',
      'server': 'old.example',
      'port': 443,
      'protocol': 'swock',
      'serverPublicKey': 'old-server-key',
      'clientPrivateKey': 'old-client-key',
      'tunnelAddress': '10.8.0.2',
    });

    expect(profile.protocol, VpnProtocol.xray);
    expect(profile.showXrayConfig, isTrue);
    expect(profile.toJson(), isNot(contains('serverPublicKey')));
    expect(profile.toJson(), isNot(contains('clientPrivateKey')));
    expect(profile.toJson(), isNot(contains('tunnelAddress')));
  });

  test('VPN core runtime is persisted independently from protocol', () {
    final profile = VpnProfile(
      id: 'singbox-test',
      name: 'Sing-box profile',
      server: 'proxy.example',
      port: 443,
      protocol: VpnProtocol.vless,
      core: VpnCore.singbox,
      uuid: '00000000-0000-0000-0000-000000000001',
      createdAt: DateTime.utc(2026),
      lastUsedAt: DateTime.utc(2026),
    );

    final restored = VpnProfile.fromJson(profile.toJson());
    expect(restored.protocol, VpnProtocol.vless);
    expect(restored.core, VpnCore.singbox);
  });

  test('profiles without a persisted port do not receive a default port', () {
    final profile = VpnProfile.fromJson({
      'id': 'missing-port',
      'name': 'Missing port',
      'server': 'proxy.example',
    });

    expect(profile.port, 0);
  });

  test('endpoint port overrides persist and can be cleared', () {
    final profile = VpnProfile(
      id: 'imported-port-override',
      name: 'Imported profile',
      server: 'proxy.example',
      port: 443,
      endpointPortOverride: 2053,
      xrayShareLink: 'vless://id@proxy.example:443',
      protocol: VpnProtocol.vless,
      createdAt: DateTime.utc(2026),
      lastUsedAt: DateTime.utc(2026),
    );
    final restored = VpnProfile.fromJson(profile.toJson());

    expect(restored.endpointPortOverride, 2053);
    expect(
      restored.copyWith(clearEndpointPortOverride: true).endpointPortOverride,
      isNull,
    );
  });

  test('SSH proxy port has no fixed default and persists a custom port', () {
    const ssh = SshTunnelConfig();
    expect(ssh.proxyPort, 0);

    final profile = VpnProfile(
      id: 'ssh-custom-proxy',
      name: 'SSH custom proxy',
      server: 'ssh.example',
      port: 22,
      protocol: VpnProtocol.ssh,
      ssh: const SshTunnelConfig(
        proxyEnabled: true,
        proxyHost: 'proxy.example',
        proxyPort: 3128,
      ),
      createdAt: DateTime.utc(2026),
      lastUsedAt: DateTime.utc(2026),
    );

    final restored = VpnProfile.fromJson(profile.toJson());
    expect(restored.ssh.proxyPort, 3128);
  });

  test('legacy SSH-only settings are ignored and not persisted', () {
    final ssh = SshTunnelConfig.fromJson({
      'username': 'tunnel',
      'helperPath': '/legacy/ssh-helper',
      'ipv6Enabled': false,
    });

    expect(ssh.username, 'tunnel');
    expect(ssh.toJson().containsKey('helperPath'), isFalse);
    expect(ssh.toJson().containsKey('ipv6Enabled'), isFalse);
  });

  test('Xray JSON imports retain Shadowsocks cipher and WebSocket path', () {
    final profile = SwockUriService.importUri(jsonEncode({
      'log': {'loglevel': 'warning'},
      'outbounds': [
        {
          'tag': 'proxy',
          'protocol': 'shadowsocks',
          'settings': {
            'servers': [
              {
                'address': 'ss.example',
                'port': 9443,
                'method': '2022-blake3-aes-128-gcm',
                'password': 'test-password',
              }
            ]
          },
          'streamSettings': {
            'network': 'ws',
            'security': 'tls',
            'tlsSettings': {'serverName': 'ss.example'},
            'wsSettings': {
              'path': '/custom-tunnel',
              'headers': {'Host': 'ss.example'},
            },
          },
        }
      ],
    }));

    expect(profile.protocol, VpnProtocol.shadowsocks);
    expect(profile.cipher, '2022-blake3-aes-128-gcm');
    expect(profile.port, 9443);
    expect(profile.webSocket.enabled, isTrue);
    expect(profile.webSocket.path, '/custom-tunnel');
  });

  test('native Sing-box JSON imports without reducing its config', () {
    final nativeConfig = {
      'log': {'level': 'warn'},
      'inbounds': [
        {
          'type': 'tun',
          'tag': 'tun-in',
          'address': ['26.26.26.1/30', 'fd26:26:26::1/126'],
          'auto_route': true,
        },
      ],
      'outbounds': [
        {
          'type': 'selector',
          'tag': 'proxy',
          'outbounds': ['edge'],
          'default': 'edge',
        },
        {
          'type': 'tuic',
          'tag': 'edge',
          'server': 'tuic.example',
          'server_port': 443,
          'uuid': '00000000-0000-0000-0000-000000000001',
          'password': 'fixture-only',
        },
      ],
      'endpoints': [
        {
          'type': 'wireguard',
          'tag': 'wg-edge',
          'address': ['10.0.0.2/32'],
        },
      ],
      'route': {
        'rules': [
          {'protocol': 'dns', 'action': 'hijack-dns'},
        ],
        'final': 'proxy',
      },
    };

    final profile = SwockUriService.importUri(jsonEncode(nativeConfig));
    final restored = VpnProfile.fromJson(profile.toJson());
    final savedConfig = jsonDecode(restored.xrayConfig) as Map<String, dynamic>;

    expect(profile.core, VpnCore.singbox);
    expect(profile.protocol, VpnProtocol.xray);
    expect(savedConfig, nativeConfig);
    expect(restored.xrayConfig, profile.xrayConfig);
  });

  test('single native Sing-box outbounds import without losing options', () {
    final outbound = {
      'type': 'wireguard',
      'tag': 'wg-edge',
      'server': 'wg.example',
      'server_port': 51820,
      'local_address': ['10.0.0.2/32'],
      'private_key': 'fixture-private-key',
      'peer_public_key': 'fixture-public-key',
    };

    final profile = SwockUriService.importUri(jsonEncode(outbound));
    final config = jsonDecode(profile.xrayConfig) as Map<String, dynamic>;

    expect(profile.core, VpnCore.singbox);
    expect(profile.name, 'wg-edge');
    expect(profile.server, 'wg.example');
    expect(profile.port, 51820);
    expect((config['outbounds'] as List).single, outbound);
    expect((config['route'] as Map)['final'], 'wg-edge');
  });

  test('native Sing-box transport metadata is detected', () {
    final outbound = {
      'type': 'vless',
      'tag': 'grpc-edge',
      'server': 'grpc.example',
      'server_port': 443,
      'uuid': '00000000-0000-0000-0000-000000000001',
      'transport': {
        'type': 'grpc',
        'service_name': 'tunnel',
      },
      'tls': {
        'enabled': true,
        'server_name': 'cdn.example',
      },
    };

    final profile = SwockUriService.importUri(jsonEncode(outbound));

    expect(profile.core, VpnCore.singbox);
    expect(profile.transport, TransportMode.grpc);
    expect(profile.webSocket.path, 'tunnel');
    expect(profile.tls.enabled, isTrue);
    expect(profile.tls.serverName, 'cdn.example');
  });

  test('NekoBox built-in share schemes become native Sing-box outbounds', () {
    final profiles = <String, Map<String, dynamic>>{
      'anytls://fixture-password@anytls.example:443?sni=front.example&insecure=1#AnyTLS':
          {
        'type': 'anytls',
        'password': 'fixture-password',
        'tls': {
          'enabled': true,
          'server_name': 'front.example',
          'insecure': true,
        },
      },
      'shadowtls://fixture-password@shadow.example:443?version=3&sni=front.example':
          {
        'type': 'shadowtls',
        'password': 'fixture-password',
        'version': 3,
        'tls': {
          'enabled': true,
          'server_name': 'front.example',
        },
      },
      'tuic://00000000-0000-0000-0000-000000000001:fixture-password@tuic.example:443?congestion_control=bbr&udp_relay_mode=native&sni=front.example':
          {
        'type': 'tuic',
        'uuid': '00000000-0000-0000-0000-000000000001',
        'password': 'fixture-password',
        'congestion_control': 'bbr',
        'udp_relay_mode': 'native',
        'tls': {
          'enabled': true,
          'server_name': 'front.example',
        },
      },
      'hysteria://hy.example:443?auth=fixture-auth&peer=front.example&upmbps=20&downmbps=100&mport=443,8443-8445':
          {
        'type': 'hysteria',
        'auth_str': 'fixture-auth',
        'up_mbps': 20,
        'down_mbps': 100,
        'tls': {
          'enabled': true,
          'server_name': 'front.example',
        },
        'server_ports': ['443', '8443:8445'],
      },
      'socks4a://proxy-user@socks.example:1080': {
        'type': 'socks',
        'version': '4a',
        'username': 'proxy-user',
      },
      'https://proxy-user:fixture-password@https-proxy.example:8443?sni=proxy.example':
          {
        'type': 'http',
        'username': 'proxy-user',
        'password': 'fixture-password',
        'tls': {
          'enabled': true,
          'server_name': 'proxy.example',
        },
      },
    };

    for (final entry in profiles.entries) {
      final profile = SwockUriService.importUri(entry.key);
      final config = jsonDecode(profile.xrayConfig) as Map<String, dynamic>;
      final outbound =
          (config['outbounds'] as List).single as Map<String, dynamic>;

      expect(profile.core, VpnCore.singbox, reason: entry.key);
      expect(outbound, containsPair('server', Uri.parse(entry.key).host));
      for (final option in entry.value.entries) {
        expect(outbound[option.key], option.value, reason: entry.key);
      }
    }
  });

  test('invalid native share options fail with a format error', () {
    expect(
      () => SwockUriService.importUri(
        'hysteria://hy.example:443?protocol=faketcp',
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => SwockUriService.importUri(
        'hysteria://hy.example:443?mport=8445-8443',
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => SwockUriService.importUri(
        'shadowtls://secret@shadow.example:443?version=4',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('Xray JSON retains native outbounds not represented in profile fields',
      () {
    final nativeConfig = {
      'outbounds': [
        {
          'tag': 'deny',
          'protocol': 'blackhole',
          'settings': {
            'response': {'type': 'http'},
          },
        },
        {
          'tag': 'direct',
          'protocol': 'freedom',
          'settings': {'domainStrategy': 'UseIP'},
        },
      ],
      'routing': {
        'rules': [
          {
            'type': 'field',
            'domain': ['example.invalid'],
            'outboundTag': 'deny',
          },
        ],
      },
    };

    final profile = SwockUriService.importUri(jsonEncode(nativeConfig));
    final savedConfig = jsonDecode(profile.xrayConfig) as Map<String, dynamic>;

    expect(profile.core, VpnCore.xray);
    expect(profile.protocol, VpnProtocol.xray);
    expect(savedConfig, nativeConfig);
  });

  test('Xray JSON keeps Shadowsocks 2022 WebSocket routing and mux settings',
      () {
    final profile = SwockUriService.importUri(jsonEncode({
      'log': {'loglevel': 'warning'},
      'inbounds': [
        {
          'listen': '127.0.0.1',
          'port': 10808,
          'protocol': 'socks',
          'settings': {'auth': 'noauth', 'udp': true},
        },
      ],
      'outbounds': [
        {
          'tag': 'ss2022-ws-tls',
          'protocol': 'shadowsocks',
          'settings': {
            'servers': [
              {
                'address': 'proxy.example',
                'port': 443,
                'method': '2022-blake3-chacha20-poly1305',
                'password': 'fixture-only',
              },
            ],
          },
          'streamSettings': {
            'network': 'ws',
            'security': 'tls',
            'tlsSettings': {'serverName': 'cdn.example'},
            'wsSettings': {
              'path': '/ss2022-ws/24',
              'headers': {'Host': 'cdn.example'},
            },
          },
          'mux': {
            'enabled': true,
            'xudpConcurrency': 16,
            'xudpProxyUDP443': 'allow',
          },
        },
      ],
      'routing': {
        'rules': [
          {
            'type': 'field',
            'network': 'udp',
            'outboundTag': 'ss2022-ws-tls',
          },
        ],
      },
    }));

    final config = jsonDecode(profile.xrayConfig) as Map<String, dynamic>;
    final outbound = (config['outbounds'] as List).single as Map;
    final stream = outbound['streamSettings'] as Map;
    final mux = outbound['mux'] as Map;
    final route = ((config['routing'] as Map)['rules'] as List).single as Map;

    expect(profile.protocol, VpnProtocol.shadowsocks);
    expect(profile.core, VpnCore.xray);
    expect(profile.cipher, '2022-blake3-chacha20-poly1305');
    expect(profile.webSocket.path, '/ss2022-ws/24');
    expect((stream['wsSettings'] as Map)['headers'], {'Host': 'cdn.example'});
    expect(mux['xudpConcurrency'], 16);
    expect(route['outboundTag'], 'ss2022-ws-tls');
  });
}
