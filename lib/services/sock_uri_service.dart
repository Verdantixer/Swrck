import 'dart:convert';
import 'package:uuid/uuid.dart';

import '../models/vpn_profile.dart';
import 'xray_json_service.dart';

class SwockUriService {
  static VpnProfile importUri(String value) {
    var trimmed = value.trim();
    if (trimmed.startsWith('\uFEFF')) {
      trimmed = trimmed.substring(1).trimLeft();
    }
    if (trimmed.startsWith('```')) {
      final firstLine = trimmed.indexOf('\n');
      final closingFence = trimmed.lastIndexOf('```');
      if (firstLine >= 0 && closingFence > firstLine) {
        trimmed = trimmed.substring(firstLine + 1, closingFence).trim();
      }
    }
    final lower = trimmed.toLowerCase();
    final isSingleLine = !trimmed.contains(RegExp(r'\r?\n'));
    final possibleJson = trimmed.replaceFirst(
      RegExp(r'^(?:(?:&#x20;|&#32;|&nbsp;)|\s)+', caseSensitive: false),
      '',
    );

    if (isSingleLine && lower.startsWith('swock://')) {
      throw const FormatException(
        'Swock tunnel profiles are no longer supported. Import a supported proxy link or Xray JSON.',
      );
    } else if (isSingleLine && lower.startsWith('trojan://')) {
      return _importTrojanUri(trimmed);
    } else if (isSingleLine && lower.startsWith('vless://')) {
      return _importVlessUri(trimmed);
    } else if (isSingleLine && lower.startsWith('vmess://')) {
      return _importVmessUri(trimmed);
    } else if (isSingleLine &&
        (lower.startsWith('ss://') || lower.startsWith('shadowsocks://'))) {
      return _importShadowsocksUri(trimmed);
    } else if (isSingleLine && lower.startsWith('ssh://')) {
      return _importSshUri(trimmed);
    }

    final firstLine = trimmed.split(RegExp(r'\r?\n')).first.trim();
    final candidate = Uri.tryParse(firstLine);
    if (candidate != null && candidate.hasScheme && candidate.host.isNotEmpty) {
      if (const {
        'anytls',
        'shadowtls',
        'tuic',
        'hysteria',
        'socks4',
        'socks4a',
        'https',
      }.contains(candidate.scheme.toLowerCase())) {
        return _importSingboxShareUri(candidate);
      }
      return _importXrayShareText(trimmed, candidate);
    }

    if (possibleJson.startsWith('{') ||
        possibleJson.startsWith('//') ||
        possibleJson.startsWith('/*') ||
        possibleJson.startsWith(r'{\"') ||
        possibleJson.toLowerCase().startsWith('&#x7b;') ||
        possibleJson.startsWith('&#123;') ||
        possibleJson.startsWith('&quot;{') ||
        possibleJson.startsWith('"{')) {
      return _importCoreJson(trimmed);
    }
    throw const FormatException(
        'Enter a supported proxy share link, Xray JSON, or SSH profile URI.');
  }

  static VpnProfile _importXrayShareText(String text, Uri firstUri) {
    final now = DateTime.now();
    final scheme = firstUri.scheme.toLowerCase();
    final protocol = switch (scheme) {
      'vless' => VpnProtocol.vless,
      'vmess' => VpnProtocol.vmess,
      'trojan' => VpnProtocol.trojan,
      'ss' || 'shadowsocks' => VpnProtocol.shadowsocks,
      'hysteria2' || 'hy2' => VpnProtocol.hysteria2,
      'socks' || 'socks5' => VpnProtocol.socks,
      'http' => VpnProtocol.http,
      _ => VpnProtocol.xray,
    };
    final hysteriaAuth = protocol == VpnProtocol.hysteria2
        ? (firstUri.userInfo.isNotEmpty
            ? Uri.decodeComponent(firstUri.userInfo)
            : (firstUri.queryParameters['auth'] ?? ''))
        : '';
    final hysteriaSni = protocol == VpnProtocol.hysteria2
        ? (firstUri.queryParameters['sni'] ?? '').trim()
        : '';
    final hysteriaObfs = protocol == VpnProtocol.hysteria2
        ? (firstUri.queryParameters['obfs'] ?? '').trim().toLowerCase()
        : '';
    final hysteriaObfsPassword = protocol == VpnProtocol.hysteria2
        ? (firstUri.queryParameters['obfs-password'] ??
                firstUri.queryParameters['obfsPassword'] ??
                '')
            .trim()
        : '';
    return VpnProfile(
      id: const Uuid().v4(),
      name: firstUri.fragment.isNotEmpty
          ? Uri.decodeComponent(firstUri.fragment)
          : (text.contains(RegExp(r'\r?\n'))
              ? 'Xray subscription'
              : '${scheme.toUpperCase()}-${firstUri.host}'),
      server: firstUri.host,
      port: _requiredUriPort(firstUri, scheme.toUpperCase()),
      protocol: protocol,
      password: hysteriaAuth,
      hysteriaObfs: hysteriaObfs,
      hysteriaObfsPassword: hysteriaObfsPassword,
      tls: TlsConfig(
        enabled: protocol == VpnProtocol.hysteria2,
        sni: hysteriaSni,
        serverName: hysteriaSni,
      ),
      xrayShareLink: text,
      showXrayConfig: true,
      createdAt: now,
      lastUsedAt: now,
      isSelected: true,
    );
  }

  static VpnProfile _importCoreJson(String text) {
    try {
      final parsedConfig = parseXrayJson(text);
      final config = parsedConfig['type'] is String
          ? {
              'outbounds': [
                {...parsedConfig, 'tag': parsedConfig['tag'] ?? 'proxy'},
              ],
              'route': {
                'final': parsedConfig['tag'] is String &&
                        (parsedConfig['tag'] as String).isNotEmpty
                    ? parsedConfig['tag']
                    : 'proxy',
              },
            }
          : parsedConfig;
      final outbound = primaryXrayOutbound(config);
      if (outbound == null) {
        throw const FormatException(
            'Core JSON must contain an outbounds array or a single Sing-box outbound.');
      }
      if (isSingboxJson(config)) {
        return _importSingboxJson(config);
      }
      final protocolName =
          (outbound['protocol'] as String? ?? '').toLowerCase();
      final settings = _map(outbound['settings']);
      final endpoint = _xrayEndpoint(protocolName, settings);
      final stream = _map(outbound['streamSettings']);
      final tlsSettings = _map(stream['tlsSettings']);
      final wsSettings = _map(stream['wsSettings']);
      final headers = _map(wsSettings['headers']);
      final httpUpgradeSettings = _map(stream['httpupgradeSettings']);
      final httpSettings = _map(stream['httpSettings']);
      final grpcSettings = _map(stream['grpcSettings']);
      final xhttpSettings = _map(stream['xhttpSettings']);
      final xhttpPath = xhttpSettings['path']?.toString().trim() ?? '';
      final effectiveHeaders =
          headers.isNotEmpty ? headers : _map(httpSettings['headers']);
      final users = _listOfMaps(endpoint['users']);
      final user = users.isEmpty ? <String, dynamic>{} : users.first;
      final isTls =
          (stream['security'] as String? ?? '').toLowerCase() == 'tls';
      final network = (stream['network'] as String? ?? 'tcp').toLowerCase();
      final transport = TransportMode.fromNetwork(network, tls: isTls);
      final isWebSocket = transport.isWebSocket;
      final httpHosts = httpSettings['host'];
      final transportHost = switch (network) {
        'http' => httpHosts is List && httpHosts.isNotEmpty
            ? httpHosts.first.toString()
            : httpHosts?.toString() ?? '',
        'httpupgrade' => httpUpgradeSettings['host']?.toString() ?? '',
        'xhttp' || 'splithttp' => xhttpSettings['host']?.toString() ?? '',
        'grpc' => grpcSettings['authority']?.toString() ?? '',
        _ => _headerValue(effectiveHeaders, 'host'),
      };
      final transportPath = switch (network) {
        'grpc' => grpcSettings['serviceName']?.toString() ?? '',
        'httpupgrade' => httpUpgradeSettings['path']?.toString() ?? '',
        'http' => httpSettings['path']?.toString() ?? '',
        'xhttp' || 'splithttp' => xhttpPath,
        _ => wsSettings['path']?.toString() ?? '',
      };
      final sni = (tlsSettings['serverName'] as String? ?? '').trim();
      final server = (endpoint['address'] ?? '').toString().trim();
      final port = _number(endpoint['port'], fallback: 0);
      final knownProtocol = switch (protocolName) {
        'vless' => VpnProtocol.vless,
        'vmess' => VpnProtocol.vmess,
        'trojan' => VpnProtocol.trojan,
        'shadowsocks' => VpnProtocol.shadowsocks,
        'hysteria' => VpnProtocol.hysteria2,
        'socks' => VpnProtocol.socks,
        'http' => VpnProtocol.http,
        _ => VpnProtocol.xray,
      };
      final tag = (outbound['tag'] as String? ?? '').trim();
      final now = DateTime.now();
      return VpnProfile(
        id: const Uuid().v4(),
        name: tag.isNotEmpty
            ? tag
            : server.isNotEmpty
                ? '${protocolName.toUpperCase()}-$server'
                : 'Xray configuration',
        server: server.isNotEmpty ? server : 'Xray configuration',
        port: port,
        protocol: knownProtocol,
        uuid: (user['id'] ?? '').toString(),
        alterId: _number(user['alterId'], fallback: 0),
        flow: (user['flow'] ?? '').toString(),
        security: (user['security'] ?? 'auto').toString(),
        cipher: (endpoint['method'] ??
                endpoint['cipher'] ??
                settings['method'] ??
                '')
            .toString(),
        password: (endpoint['password'] ??
                user['password'] ??
                _map(stream['hysteriaSettings'])['auth'] ??
                '')
            .toString(),
        transport: transport,
        webSocket: WebSocketConfig(
          enabled: isWebSocket,
          host: transportHost,
          path: transportPath,
          headers: effectiveHeaders
              .map((key, value) => MapEntry(key, value.toString())),
          connectionOptions: xhttpSettings['mode'] == null
              ? const {}
              : {'mode': xhttpSettings['mode'].toString()},
        ),
        tls: TlsConfig(
          enabled: isTls,
          sni: sni,
          serverName: sni,
          allowInsecureCertificate: tlsSettings['allowInsecure'] == true,
          alpn: (tlsSettings['alpn'] as List<dynamic>? ?? const [])
              .map((value) => value.toString())
              .toList(),
        ),
        xrayShareLink: '',
        xrayConfig: const JsonEncoder.withIndent('  ').convert(config),
        showXrayConfig: true,
        createdAt: now,
        lastUsedAt: now,
        isSelected: true,
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Invalid core JSON configuration.');
    }
  }

  static VpnProfile _importSingboxJson(
    Map<String, dynamic> config, {
    String? name,
    String shareLink = '',
  }) {
    final outbounds = _listOfMaps(config['outbounds']);
    final outbound = outbounds.firstWhere(
      (item) => item['tag'] is String && (item['tag'] as String).isNotEmpty,
      orElse: () => outbounds.first,
    );
    final tag = (outbound['tag'] as String? ?? '').trim();
    final outboundType = (outbound['type'] as String? ?? '').toLowerCase();
    final transportSettings = _map(outbound['transport']);
    final tlsSettings = _map(outbound['tls']);
    final network = (transportSettings['type'] as String? ??
            (const {'vless', 'vmess', 'trojan', 'shadowsocks'}
                    .contains(outboundType)
                ? 'tcp'
                : ''))
        .toLowerCase();
    final transport = TransportMode.fromNetwork(
      network,
      tls: tlsSettings['enabled'] == true,
    );
    final transportHeaders = _map(transportSettings['headers']);
    final transportHost = transportSettings['host'] is List
        ? ((transportSettings['host'] as List).isEmpty
            ? ''
            : (transportSettings['host'] as List).first.toString())
        : transportSettings['host']?.toString() ??
            _headerValue(transportHeaders, 'host');
    final transportPath = transportSettings['path']?.toString() ??
        transportSettings['service_name']?.toString() ??
        '';
    final sni = (tlsSettings['server_name'] as String? ?? '').trim();
    final now = DateTime.now();
    return VpnProfile(
      id: const Uuid().v4(),
      name: name ?? (tag.isEmpty ? 'Sing-box configuration' : tag),
      server: (outbound['server'] as String?) ?? 'Sing-box configuration',
      port: _number(outbound['server_port'], fallback: 0),
      protocol: VpnProtocol.xray,
      core: VpnCore.singbox,
      transport: transport,
      webSocket: WebSocketConfig(
        enabled: transport.isWebSocket,
        path: transportPath,
        host: transportHost,
        headers: transportHeaders
            .map((key, value) => MapEntry(key, value.toString())),
      ),
      tls: TlsConfig(
        enabled: tlsSettings['enabled'] == true,
        sni: sni,
        serverName: sni,
        allowInsecureCertificate: tlsSettings['insecure'] == true,
        alpn: (tlsSettings['alpn'] as List<dynamic>? ?? const [])
            .map((value) => value.toString())
            .toList(),
      ),
      xrayConfig: const JsonEncoder.withIndent('  ').convert(config),
      xrayShareLink: shareLink,
      showXrayConfig: true,
      createdAt: now,
      lastUsedAt: now,
      isSelected: true,
    );
  }

  static VpnProfile _importSingboxShareUri(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    final server = uri.host;
    final port = _requiredUriPort(uri, scheme.toUpperCase());
    final query = uri.queryParameters;
    final username = Uri.decodeComponent(uri.userInfo);
    final outbound = <String, dynamic>{
      'type': switch (scheme) {
        'socks4' || 'socks4a' => 'socks',
        'https' => 'http',
        'hysteria' => 'hysteria',
        _ => scheme,
      },
      'tag': 'proxy',
      'server': server,
      'server_port': port,
    };

    switch (scheme) {
      case 'anytls':
        if (username.isEmpty) {
          throw const FormatException('AnyTLS links must include a password.');
        }
        outbound['password'] = username;
        outbound['tls'] = _singboxTls(query, server);
      case 'shadowtls':
        if (username.isEmpty) {
          throw const FormatException(
            'ShadowTLS links must include a password.',
          );
        }
        final version = _number(query['version'], fallback: 3);
        if (version < 1 || version > 3) {
          throw const FormatException('ShadowTLS version must be 1, 2, or 3.');
        }
        outbound
          ..['password'] = username
          ..['version'] = version
          ..['tls'] = _singboxTls(query, server);
      case 'tuic':
        final separator = username.indexOf(':');
        final uuid =
            separator < 0 ? username : username.substring(0, separator);
        if (uuid.isEmpty) {
          throw const FormatException('TUIC links must include a UUID.');
        }
        outbound
          ..['uuid'] = uuid
          ..['password'] =
              separator < 0 ? '' : username.substring(separator + 1)
          ..['congestion_control'] =
              query['congestion_control']?.trim().isNotEmpty == true
                  ? query['congestion_control']!.trim()
                  : 'cubic'
          ..['tls'] = _singboxTls(query, server);
        final relayMode = query['udp_relay_mode']?.trim();
        if (relayMode != null && relayMode.isNotEmpty) {
          outbound['udp_relay_mode'] = relayMode;
        }
        if (query['zero_rtt_handshake'] == '1' || query['reduce_rtt'] == '1') {
          outbound['zero_rtt_handshake'] = true;
        }
      case 'hysteria':
        final transport = (query['protocol'] ?? 'udp').trim().toLowerCase();
        if (transport.isNotEmpty && transport != 'udp') {
          throw const FormatException(
            'This Hysteria 1 transport requires an external plugin and cannot run in the bundled Sing-box core.',
          );
        }
        final auth = (query['auth'] ?? '').trim();
        if (auth.isNotEmpty) outbound['auth_str'] = auth;
        final upMbps = int.tryParse(query['upmbps'] ?? '');
        final downMbps = int.tryParse(query['downmbps'] ?? '');
        if (upMbps != null && upMbps > 0) outbound['up_mbps'] = upMbps;
        if (downMbps != null && downMbps > 0) {
          outbound['down_mbps'] = downMbps;
        }
        final obfs = (query['obfsParam'] ?? query['obfs'] ?? '').trim();
        if (obfs.isNotEmpty) outbound['obfs'] = obfs;
        outbound['tls'] = _singboxTls(
          {
            ...query,
            'sni': query['peer'] ?? query['sni'] ?? '',
          },
          server,
        );
        final multiPort = (query['mport'] ?? '').trim();
        if (multiPort.isNotEmpty) {
          outbound
            ..remove('server_port')
            ..['server_ports'] = _hysteriaServerPorts(multiPort);
        }
      case 'socks4':
      case 'socks4a':
        outbound['version'] = scheme == 'socks4' ? '4' : '4a';
        if (username.isNotEmpty) outbound['username'] = username;
      case 'https':
        outbound['tls'] = _singboxTls(query, server);
        if (username.isNotEmpty) {
          final separator = username.indexOf(':');
          outbound['username'] =
              separator < 0 ? username : username.substring(0, separator);
          if (separator >= 0) {
            outbound['password'] = username.substring(separator + 1);
          }
        }
    }

    final config = <String, dynamic>{
      'outbounds': [outbound],
      'route': {'final': 'proxy'},
    };
    final name = uri.fragment.isNotEmpty
        ? Uri.decodeComponent(uri.fragment)
        : '${scheme.toUpperCase()}-$server';
    return _importSingboxJson(config, name: name, shareLink: uri.toString());
  }

  static Map<String, dynamic> _singboxTls(
    Map<String, String> query,
    String server,
  ) {
    final tls = <String, dynamic>{
      'enabled': true,
      'server_name': (query['sni'] ?? query['peer'] ?? '').trim().isNotEmpty
          ? (query['sni'] ?? query['peer'])!.trim()
          : server,
    };
    final alpn = (query['alpn'] ?? '')
        .split(RegExp(r'[,\\n]'))
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList();
    if (alpn.isNotEmpty) tls['alpn'] = alpn;
    if (query['insecure'] == '1' ||
        query['insecure'] == 'true' ||
        query['allow_insecure'] == '1' ||
        query['allowInsecure'] == '1') {
      tls['insecure'] = true;
    }
    final fingerprint = (query['fp'] ?? '').trim();
    if (fingerprint.isNotEmpty) {
      tls['utls'] = {'enabled': true, 'fingerprint': fingerprint};
    }
    return tls;
  }

  static List<String> _hysteriaServerPorts(String value) {
    final ports = value.split(',').map((entry) {
      final range = entry.trim().replaceFirst('-', ':');
      final parts = range.split(':');
      bool validPort(String part) {
        final port = int.tryParse(part);
        return port != null && port >= 1 && port <= 65535;
      }

      final valid = parts.length == 1
          ? validPort(parts.first)
          : parts.length == 2 && parts.every(validPort);
      final orderedRange = parts.length != 2 ||
          (valid && int.parse(parts.first) <= int.parse(parts.last));
      if (!valid || !orderedRange) {
        throw const FormatException(
          'Hysteria port hopping must use valid ports or port ranges.',
        );
      }
      return range;
    }).toList();
    if (ports.isEmpty) {
      throw const FormatException('Hysteria port hopping cannot be empty.');
    }
    return ports;
  }

  static Map<String, dynamic> _map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

  static List<Map<String, dynamic>> _listOfMaps(Object? value) => value is List
      ? value.whereType<Map>().map(Map<String, dynamic>.from).toList()
      : <Map<String, dynamic>>[];

  static Map<String, dynamic> _xrayEndpoint(
    String protocol,
    Map<String, dynamic> settings,
  ) {
    final vnext = _listOfMaps(settings['vnext']);
    if (vnext.isNotEmpty) return vnext.first;
    final servers = _listOfMaps(settings['servers']);
    if (servers.isNotEmpty) return servers.first;
    final peers = _listOfMaps(settings['peers']);
    if (peers.isNotEmpty && protocol == 'wireguard') return peers.first;
    return settings;
  }

  static int _number(Object? value, {required int fallback}) => value is num
      ? value.toInt()
      : int.tryParse(value?.toString() ?? '') ?? fallback;

  static int _requiredUriPort(Uri uri, String protocol) {
    final port = uri.hasPort ? uri.port : 0;
    if (port < 1 || port > 65535) {
      throw FormatException(
        '$protocol profiles must include an explicit server port from 1 to 65535.',
      );
    }
    return port;
  }

  static int _requiredPort(Object? value, String protocol) {
    final port =
        value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');
    if (port == null || port < 1 || port > 65535) {
      throw FormatException(
        '$protocol profiles must include a server port from 1 to 65535.',
      );
    }
    return port;
  }

  static String _decodeBase64Text(String value) {
    final standardAlphabet = value.replaceAll('-', '+').replaceAll('_', '/');
    return utf8.decode(
      base64.decode(base64.normalize(standardAlphabet)),
    );
  }

  static String _headerValue(Map<String, dynamic> headers, String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name) return entry.value.toString();
    }
    return '';
  }

  static VpnProfile _importSshUri(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) {
      throw const FormatException('Enter a valid ssh:// profile URI.');
    }
    final credentials = uri.userInfo.split(':');
    final now = DateTime.now();
    return VpnProfile(
      id: const Uuid().v4(),
      name: uri.fragment.isNotEmpty
          ? Uri.decodeComponent(uri.fragment)
          : 'SSH-${uri.host}',
      server: uri.host,
      port: _requiredUriPort(uri, 'SSH'),
      protocol: VpnProtocol.ssh,
      password:
          credentials.length > 1 ? Uri.decodeComponent(credentials.last) : '',
      ssh: SshTunnelConfig(
        username: credentials.isNotEmpty
            ? Uri.decodeComponent(credentials.first)
            : '',
      ),
      showXrayConfig: false,
      createdAt: now,
      lastUsedAt: now,
      isSelected: true,
    );
  }

  static VpnProfile _importTrojanUri(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) throw const FormatException('Invalid trojan:// URI');
    final password = uri.userInfo;
    final server = uri.host;
    final port = _requiredUriPort(uri, 'Trojan');
    final name = uri.fragment.isNotEmpty
        ? Uri.decodeComponent(uri.fragment)
        : 'Trojan-$server';
    final sni =
        (uri.queryParameters['sni'] ?? uri.queryParameters['peer'] ?? '')
            .trim();
    final wsHost = (uri.queryParameters['host'] ?? sni).trim();
    final wsPath = Uri.decodeComponent(uri.queryParameters['path'] ?? '');
    final type = uri.queryParameters['type'] ??
        uri.queryParameters['headerType'] ??
        'tcp';
    final security = uri.queryParameters['security'] ?? 'none';
    final isTls = security == 'tls';
    final transport = TransportMode.fromNetwork(type, tls: isTls);
    final isWs = transport.isWebSocket;
    final transportPath = type.toLowerCase() == 'grpc'
        ? uri.queryParameters['serviceName'] ??
            uri.queryParameters['service_name'] ??
            wsPath
        : wsPath;

    final now = DateTime.now();
    return VpnProfile(
      id: const Uuid().v4(),
      name: name,
      server: server,
      port: port,
      protocol: VpnProtocol.trojan,
      xrayShareLink: value,
      password: password,
      transport: transport,
      webSocket: WebSocketConfig(
        enabled: isWs,
        host: wsHost.isNotEmpty ? wsHost : sni,
        path: transportPath,
        connectionOptions: uri.queryParameters['mode'] == null
            ? const {}
            : {'mode': uri.queryParameters['mode']!},
      ),
      tls: TlsConfig(
        enabled: isTls,
        sni: sni.isNotEmpty ? sni : wsHost,
        serverName: sni.isNotEmpty ? sni : wsHost,
        allowInsecureCertificate: uri.queryParameters['allowInsecure'] == '1',
      ),
      createdAt: now,
      lastUsedAt: now,
      isSelected: true,
    );
  }

  static VpnProfile _importVlessUri(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) throw const FormatException('Invalid vless:// URI');
    final uuid = uri.userInfo;
    final server = uri.host;
    final port = _requiredUriPort(uri, 'VLESS');
    final name = uri.fragment.isNotEmpty
        ? Uri.decodeComponent(uri.fragment)
        : 'VLESS-$server';
    final sni = (uri.queryParameters['sni'] ?? '').trim();
    final wsHost = (uri.queryParameters['host'] ?? sni).trim();
    final wsPath = Uri.decodeComponent(uri.queryParameters['path'] ?? '');
    final flow = uri.queryParameters['flow'] ?? '';
    final type = uri.queryParameters['type'] ?? 'tcp';
    final security = uri.queryParameters['security'] ?? 'none';
    final isTls = security == 'tls';
    final transport = TransportMode.fromNetwork(type, tls: isTls);
    final isWs = transport.isWebSocket;
    final transportPath = type.toLowerCase() == 'grpc'
        ? uri.queryParameters['serviceName'] ??
            uri.queryParameters['service_name'] ??
            wsPath
        : wsPath;

    final now = DateTime.now();
    return VpnProfile(
      id: const Uuid().v4(),
      name: name,
      server: server,
      port: port,
      protocol: VpnProtocol.vless,
      xrayShareLink: value,
      uuid: uuid,
      flow: flow,
      transport: transport,
      webSocket: WebSocketConfig(
        enabled: isWs,
        host: wsHost.isNotEmpty ? wsHost : sni,
        path: transportPath,
        connectionOptions: uri.queryParameters['mode'] == null
            ? const {}
            : {'mode': uri.queryParameters['mode']!},
      ),
      tls: TlsConfig(
        enabled: isTls,
        sni: sni.isNotEmpty ? sni : wsHost,
        serverName: sni.isNotEmpty ? sni : wsHost,
      ),
      createdAt: now,
      lastUsedAt: now,
      isSelected: true,
    );
  }

  static VpnProfile _importVmessUri(String value) {
    try {
      final raw = value.substring('vmess://'.length).trim();
      final decoded = _decodeBase64Text(raw);
      final map = jsonDecode(decoded) as Map<String, dynamic>;

      final name = map['ps'] as String? ?? 'VMess-Server';
      final server = map['add'] as String? ?? '';
      final port = _requiredPort(map['port'], 'VMess');
      final uuid = map['id'] as String? ?? '';
      final alterId = int.tryParse(map['aid']?.toString() ?? '') ?? 0;
      final net = map['net'] as String? ?? 'tcp';
      final tls = map['tls'] as String? ?? '';
      final host = map['host'] as String? ?? '';
      final path = map['path'] as String? ?? '';
      final sni = map['sni'] as String? ?? host;
      final security = map['scy'] as String? ?? 'auto';
      final isTls = tls == 'tls';
      final transport = TransportMode.fromNetwork(net, tls: isTls);
      final isWs = transport.isWebSocket;

      final now = DateTime.now();
      return VpnProfile(
        id: const Uuid().v4(),
        name: name,
        server: server,
        port: port,
        protocol: VpnProtocol.vmess,
        xrayShareLink: value,
        uuid: uuid,
        alterId: alterId,
        security: security,
        transport: transport,
        webSocket: WebSocketConfig(
          enabled: isWs,
          host: host.isNotEmpty ? host : sni,
          path: path,
          connectionOptions:
              map['mode'] == null ? const {} : {'mode': map['mode'].toString()},
        ),
        tls: TlsConfig(
          enabled: isTls,
          sni: sni.isNotEmpty ? sni : host,
          serverName: sni.isNotEmpty ? sni : host,
        ),
        createdAt: now,
        lastUsedAt: now,
        isSelected: true,
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Invalid vmess:// URI format');
    }
  }

  static VpnProfile _importShadowsocksUri(String value) {
    try {
      final uri = Uri.parse(value);
      var server = uri.host;
      var port = uri.hasPort ? uri.port : 0;
      var credentials = uri.userInfo;
      String cipher = '';
      String password = '';

      if (credentials.isNotEmpty && !credentials.contains(':')) {
        final decoded = _decodeBase64Text(credentials);
        final separator = decoded.lastIndexOf('@');
        if (server.isEmpty && separator > 0) {
          credentials = decoded.substring(0, separator);
          final endpoint =
              Uri.parse('ss://${decoded.substring(separator + 1)}');
          server = endpoint.host;
          port = endpoint.hasPort ? endpoint.port : 0;
        } else {
          credentials = decoded;
        }
      }

      final rawAuthority = value
          .substring(value.indexOf('://') + 3)
          .split(RegExp(r'[/?#]'))
          .first;
      if (credentials.isEmpty &&
          !uri.hasPort &&
          RegExp(r'^[A-Za-z0-9_=-]+$').hasMatch(rawAuthority)) {
        String? decoded;
        try {
          decoded = _decodeBase64Text(rawAuthority);
        } on FormatException {
          decoded = null;
        }
        if (decoded != null) {
          final separator = decoded.lastIndexOf('@');
          if (separator > 0) {
            credentials = decoded.substring(0, separator);
            final endpoint =
                Uri.parse('ss://${decoded.substring(separator + 1)}');
            server = endpoint.host;
            port = endpoint.hasPort ? endpoint.port : 0;
          }
        }
      }

      final separator = credentials.indexOf(':');
      if (separator >= 0) {
        cipher = credentials.substring(0, separator);
        password = credentials.substring(separator + 1);
      }

      if (server.isEmpty || port < 1 || port > 65535) {
        throw const FormatException(
          'Shadowsocks links must include a server and port from 1 to 65535.',
        );
      }

      final name = uri.fragment.isNotEmpty
          ? Uri.decodeComponent(uri.fragment)
          : 'SS-$server';
      final query = uri.queryParameters;
      final network =
          (query['type'] ?? query['network'] ?? 'tcp').trim().toLowerCase();
      final security = (query['security'] ?? '').trim().toLowerCase();
      final tlsEnabled = security == 'tls';
      final transport = TransportMode.fromNetwork(network, tls: tlsEnabled);
      final wsEnabled = transport.isWebSocket;
      final wsHost = (query['host'] ?? '').trim();
      final wsPath = query['path'] ?? '';
      final sni = (query['sni'] ?? '').trim();
      final hasTransportOptions = query.keys.any((key) => const {
            'type',
            'network',
            'security',
            'sni',
            'host',
            'path',
            'alpn'
          }.contains(key.toLowerCase()));

      final now = DateTime.now();
      return VpnProfile(
        id: const Uuid().v4(),
        name: name,
        server: server,
        port: port,
        protocol: VpnProtocol.shadowsocks,
        xrayShareLink: value,
        cipher: cipher,
        password: password,
        transport: transport,
        webSocket: WebSocketConfig(
          enabled: wsEnabled,
          host: wsHost,
          path: wsPath,
          connectionOptions:
              query['mode'] == null ? const {} : {'mode': query['mode']!},
        ),
        tls: TlsConfig(
          enabled: tlsEnabled,
          sni: sni,
          serverName: sni,
          alpn: (query['alpn'] ?? '')
              .split(',')
              .map((value) => value.trim())
              .where((value) => value.isNotEmpty)
              .toList(),
        ),
        createdAt: now,
        lastUsedAt: now,
        isSelected: true,
        showXrayConfig: !hasTransportOptions,
      );
    } catch (_) {
      throw const FormatException('Invalid ss:// URI format');
    }
  }
}
