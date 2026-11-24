import 'dart:convert';

enum VpnProtocol {
  shadowsocks,
  vless,
  vmess,
  trojan,
  hysteria2,
  ssh,
  directProxy,
  socks,
  http,
  xray
}

enum TransportMode {
  auto,
  tcp,
  kcp,
  websocket,
  websocketTls,
  httpUpgrade,
  http,
  quic,
  grpc,
  xhttp;

  static TransportMode fromNetwork(String value, {bool tls = false}) {
    switch (value.trim().toLowerCase()) {
      case 'tcp':
        return TransportMode.tcp;
      case 'kcp':
      case 'mkcp':
        return TransportMode.kcp;
      case 'ws':
      case 'websocket':
        return tls ? TransportMode.websocketTls : TransportMode.websocket;
      case 'httpupgrade':
      case 'http-upgrade':
        return TransportMode.httpUpgrade;
      case 'http':
        return TransportMode.http;
      case 'quic':
        return TransportMode.quic;
      case 'grpc':
        return TransportMode.grpc;
      case 'xhttp':
      case 'splithttp':
        return TransportMode.xhttp;
      default:
        return TransportMode.auto;
    }
  }

  String? get xrayNetwork => switch (this) {
        TransportMode.auto => null,
        TransportMode.tcp => 'tcp',
        TransportMode.kcp => 'kcp',
        TransportMode.websocket || TransportMode.websocketTls => 'ws',
        TransportMode.httpUpgrade => 'httpupgrade',
        TransportMode.http => 'http',
        TransportMode.quic => 'quic',
        TransportMode.grpc => 'grpc',
        TransportMode.xhttp => 'xhttp',
      };

  bool get isWebSocket =>
      this == TransportMode.websocket || this == TransportMode.websocketTls;

  String get label => switch (this) {
        TransportMode.auto => 'Auto',
        TransportMode.tcp => 'TCP',
        TransportMode.kcp => 'KCP',
        TransportMode.websocket => 'WebSocket',
        TransportMode.websocketTls => 'WebSocket + TLS',
        TransportMode.httpUpgrade => 'HTTPUpgrade',
        TransportMode.http => 'HTTP',
        TransportMode.quic => 'QUIC',
        TransportMode.grpc => 'gRPC',
        TransportMode.xhttp => 'XHTTP',
      };
}

enum VpnCore { xray, singbox }

enum ProxyType { none, http, socks5 }

enum DnsMode { system, custom }

class WebSocketConfig {
  final bool enabled;
  final String path;
  final String host;
  final Map<String, String> headers;
  final Map<String, String> connectionOptions;

  const WebSocketConfig({
    this.enabled = false,
    this.path = '',
    this.host = '',
    this.headers = const {},
    this.connectionOptions = const {},
  });

  factory WebSocketConfig.fromJson(Map<String, dynamic> json) {
    return WebSocketConfig(
      enabled: json['enabled'] as bool? ?? false,
      path: (json['path'] as String?) ?? '',
      host: (json['host'] as String?) ?? '',
      headers: Map<String, String>.from((json['headers'] as Map?) ?? const {}),
      connectionOptions: Map<String, String>.from(
        (json['connectionOptions'] as Map?) ?? const {},
      ),
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'path': path,
        'host': host,
        'headers': headers,
        'connectionOptions': connectionOptions,
      };
}

class TlsConfig {
  final bool enabled;
  final String sni;
  final bool allowInsecureCertificate;
  final String serverName;
  final List<String> alpn;

  const TlsConfig({
    this.enabled = false,
    this.sni = '',
    this.allowInsecureCertificate = false,
    this.serverName = '',
    this.alpn = const [],
  });

  factory TlsConfig.fromJson(Map<String, dynamic> json) {
    return TlsConfig(
      enabled: json['enabled'] as bool? ?? false,
      sni: json['sni'] as String? ?? '',
      allowInsecureCertificate:
          json['allowInsecureCertificate'] as bool? ?? false,
      serverName: json['serverName'] as String? ?? '',
      alpn: List<String>.from((json['alpn'] as List?) ?? const []),
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'sni': sni,
        'allowInsecureCertificate': allowInsecureCertificate,
        'serverName': serverName,
        'alpn': alpn,
      };
}

class ProxyConfig {
  final ProxyType type;
  final String host;
  final int port;
  final String username;
  final String password;

  const ProxyConfig({
    this.type = ProxyType.none,
    this.host = '',
    this.port = 0,
    this.username = '',
    this.password = '',
  });

  factory ProxyConfig.fromJson(Map<String, dynamic> json) {
    return ProxyConfig(
      type: ProxyType.values.firstWhere(
        (element) => element.name == (json['type'] as String? ?? 'none'),
        orElse: () => ProxyType.none,
      ),
      host: json['host'] as String? ?? '',
      port: (json['port'] as num?)?.toInt() ?? 0,
      username: json['username'] as String? ?? '',
      password: json['password'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'host': host,
        'port': port,
        'username': username,
        'password': password,
      };
}

class DnsConfig {
  final bool enabled;
  final DnsMode mode;
  final String primary;
  final String secondary;
  final String tertiary;

  const DnsConfig({
    this.enabled = false,
    this.mode = DnsMode.system,
    this.primary = '',
    this.secondary = '',
    this.tertiary = '',
  });

  factory DnsConfig.fromJson(Map<String, dynamic> json) {
    return DnsConfig(
      enabled: json['enabled'] as bool? ?? false,
      mode: DnsMode.values.firstWhere(
        (element) => element.name == (json['mode'] as String? ?? 'system'),
        orElse: () => DnsMode.system,
      ),
      primary: json['primary'] as String? ?? '',
      secondary: json['secondary'] as String? ?? '',
      tertiary: json['tertiary'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'mode': mode.name,
        'primary': primary,
        'secondary': secondary,
        'tertiary': tertiary,
      };
}

class SshTunnelConfig {
  final String username;
  final String authentication;
  final String privateKey;
  final String privateKeyPassphrase;
  final String hostKeyFingerprint;
  final bool tlsEnabled;
  final String sni;
  final bool payloadEnabled;
  final String payload;
  final bool proxyEnabled;
  final String proxyType;
  final String proxyHost;
  final int proxyPort;
  final String proxyUsername;
  final String proxyPassword;
  final int mtu;

  const SshTunnelConfig({
    this.username = '',
    this.authentication = 'password',
    this.privateKey = '',
    this.privateKeyPassphrase = '',
    this.hostKeyFingerprint = '',
    this.tlsEnabled = false,
    this.sni = '',
    this.payloadEnabled = false,
    this.payload = '',
    this.proxyEnabled = false,
    this.proxyType = 'http',
    this.proxyHost = '',
    this.proxyPort = 0,
    this.proxyUsername = '',
    this.proxyPassword = '',
    this.mtu = 1400,
  });

  factory SshTunnelConfig.fromJson(Map<String, dynamic> json) =>
      SshTunnelConfig(
        username: json['username'] as String? ?? '',
        authentication: json['authentication'] as String? ?? 'password',
        privateKey: json['privateKey'] as String? ?? '',
        privateKeyPassphrase: json['privateKeyPassphrase'] as String? ?? '',
        hostKeyFingerprint: json['hostKeyFingerprint'] as String? ?? '',
        tlsEnabled: json['tlsEnabled'] as bool? ?? false,
        sni: json['sni'] as String? ?? '',
        payloadEnabled: json['payloadEnabled'] as bool? ?? false,
        payload: json['payload'] as String? ?? '',
        proxyEnabled: json['proxyEnabled'] as bool? ?? false,
        proxyType: json['proxyType'] as String? ?? 'http',
        proxyHost: json['proxyHost'] as String? ?? '',
        proxyPort: (json['proxyPort'] as num?)?.toInt() ?? 0,
        proxyUsername: json['proxyUsername'] as String? ?? '',
        proxyPassword: json['proxyPassword'] as String? ?? '',
        mtu: (json['mtu'] as num?)?.toInt() ?? 1400,
      );

  Map<String, dynamic> toJson() => {
        'username': username,
        'authentication': authentication,
        'privateKey': privateKey,
        'privateKeyPassphrase': privateKeyPassphrase,
        'hostKeyFingerprint': hostKeyFingerprint,
        'tlsEnabled': tlsEnabled,
        'sni': sni,
        'payloadEnabled': payloadEnabled,
        'payload': payload,
        'proxyEnabled': proxyEnabled,
        'proxyType': proxyType,
        'proxyHost': proxyHost,
        'proxyPort': proxyPort,
        'proxyUsername': proxyUsername,
        'proxyPassword': proxyPassword,
        'mtu': mtu,
      };
}

class VpnProfile {
  final String id;
  final String name;
  final String server;
  final int port;
  final String uuid;
  final int alterId;
  final String flow;
  final String security;
  final VpnProtocol protocol;
  final VpnCore core;
  final String cipher;
  final String password;
  final String hysteriaObfs;
  final String hysteriaObfsPassword;
  final TransportMode transport;
  final WebSocketConfig webSocket;
  final TlsConfig tls;
  final ProxyConfig proxy;
  final SshTunnelConfig ssh;
  final DnsConfig dns;
  final String metadata;

  /// Lossless core-native JSON. Xray JSON is used with Xray-core; Sing-box JSON
  /// is used with Sing-box when [core] is [VpnCore.singbox].
  /// Kept opaque so core-specific fields survive edits and upgrades.
  final String xrayConfig;
  final String xrayShareLink;
  final int? endpointPortOverride;
  final bool showXrayConfig;
  final DateTime createdAt;
  final DateTime lastUsedAt;
  final bool favorite;
  final String? notes;
  final bool isSelected;
  final bool isLocked;
  final DateTime? expiresAt;

  const VpnProfile({
    required this.id,
    required this.name,
    required this.server,
    required this.port,
    this.uuid = '',
    this.alterId = 0,
    this.flow = '',
    this.security = 'auto',
    this.protocol = VpnProtocol.vless,
    this.core = VpnCore.xray,
    this.cipher = '',
    this.password = '',
    this.hysteriaObfs = '',
    this.hysteriaObfsPassword = '',
    this.transport = TransportMode.auto,
    this.webSocket = const WebSocketConfig(),
    this.tls = const TlsConfig(),
    this.proxy = const ProxyConfig(),
    this.ssh = const SshTunnelConfig(),
    this.dns = const DnsConfig(),
    this.metadata = '',
    this.xrayConfig = '',
    this.xrayShareLink = '',
    this.endpointPortOverride,
    this.showXrayConfig = false,
    required this.createdAt,
    required this.lastUsedAt,
    this.favorite = false,
    this.notes,
    this.isSelected = false,
    this.isLocked = false,
    this.expiresAt,
  });

  bool get hasValidServer => server.trim().isNotEmpty;
  bool get hasValidPort => port > 0 && port <= 65535;

  VpnProfile copyWith({
    String? id,
    String? name,
    String? server,
    int? port,
    String? uuid,
    int? alterId,
    String? flow,
    String? security,
    VpnProtocol? protocol,
    VpnCore? core,
    String? cipher,
    String? password,
    String? hysteriaObfs,
    String? hysteriaObfsPassword,
    TransportMode? transport,
    WebSocketConfig? webSocket,
    TlsConfig? tls,
    ProxyConfig? proxy,
    SshTunnelConfig? ssh,
    DnsConfig? dns,
    String? metadata,
    String? xrayConfig,
    String? xrayShareLink,
    int? endpointPortOverride,
    bool? showXrayConfig,
    DateTime? createdAt,
    DateTime? lastUsedAt,
    bool? favorite,
    String? notes,
    bool? isSelected,
    bool? isLocked,
    DateTime? expiresAt,
    bool clearExpiresAt = false,
    bool clearEndpointPortOverride = false,
  }) {
    return VpnProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      server: server ?? this.server,
      port: port ?? this.port,
      uuid: uuid ?? this.uuid,
      alterId: alterId ?? this.alterId,
      flow: flow ?? this.flow,
      security: security ?? this.security,
      protocol: protocol ?? this.protocol,
      core: core ?? this.core,
      cipher: cipher ?? this.cipher,
      password: password ?? this.password,
      hysteriaObfs: hysteriaObfs ?? this.hysteriaObfs,
      hysteriaObfsPassword: hysteriaObfsPassword ?? this.hysteriaObfsPassword,
      transport: transport ?? this.transport,
      webSocket: webSocket ?? this.webSocket,
      tls: tls ?? this.tls,
      proxy: proxy ?? this.proxy,
      ssh: ssh ?? this.ssh,
      dns: dns ?? this.dns,
      metadata: metadata ?? this.metadata,
      xrayConfig: xrayConfig ?? this.xrayConfig,
      xrayShareLink: xrayShareLink ?? this.xrayShareLink,
      endpointPortOverride: clearEndpointPortOverride
          ? null
          : endpointPortOverride ?? this.endpointPortOverride,
      showXrayConfig: showXrayConfig ?? this.showXrayConfig,
      createdAt: createdAt ?? this.createdAt,
      lastUsedAt: lastUsedAt ?? this.lastUsedAt,
      favorite: favorite ?? this.favorite,
      notes: notes ?? this.notes,
      isSelected: isSelected ?? this.isSelected,
      isLocked: isLocked ?? this.isLocked,
      expiresAt: clearExpiresAt ? null : expiresAt ?? this.expiresAt,
    );
  }

  factory VpnProfile.fromJson(Map<String, dynamic> json) {
    final storedProtocol = json['protocol'] as String?;
    final isLegacySwockProfile = storedProtocol?.toLowerCase() == 'swock';
    return VpnProfile(
      id: json['id'] as String? ??
          base64Url.encode(utf8.encode(DateTime.now().toIso8601String())),
      name: json['name'] as String? ?? 'Unnamed profile',
      server: json['server'] as String? ?? '',
      port: (json['port'] as num?)?.toInt() ?? 0,
      uuid: json['uuid'] as String? ?? '',
      alterId: (json['alterId'] as num?)?.toInt() ?? 0,
      flow: json['flow'] as String? ?? '',
      security: json['security'] as String? ?? 'auto',
      protocol: VpnProtocol.values.firstWhere(
        (element) =>
            element.name ==
            (isLegacySwockProfile ? 'xray' : storedProtocol ?? 'vless'),
        orElse: () => VpnProtocol.xray,
      ),
      core: VpnCore.values.firstWhere(
        (element) => element.name == (json['core'] as String? ?? 'xray'),
        orElse: () => VpnCore.xray,
      ),
      cipher: json['cipher'] as String? ?? '',
      password: json['password'] as String? ?? '',
      hysteriaObfs: json['hysteriaObfs'] as String? ?? '',
      hysteriaObfsPassword: json['hysteriaObfsPassword'] as String? ?? '',
      transport: TransportMode.values.firstWhere(
        (element) => element.name == (json['transport'] as String? ?? 'auto'),
        orElse: () => TransportMode.auto,
      ),
      webSocket: json['webSocket'] is Map
          ? WebSocketConfig.fromJson(json['webSocket'])
          : const WebSocketConfig(),
      tls: json['tls'] is Map
          ? TlsConfig.fromJson(json['tls'])
          : const TlsConfig(),
      proxy: json['proxy'] is Map
          ? ProxyConfig.fromJson(json['proxy'])
          : const ProxyConfig(),
      ssh: json['ssh'] is Map
          ? SshTunnelConfig.fromJson(
              Map<String, dynamic>.from(json['ssh'] as Map))
          : const SshTunnelConfig(),
      dns: json['dns'] is Map
          ? DnsConfig.fromJson(json['dns'])
          : const DnsConfig(),
      metadata: json['metadata'] as String? ?? '',
      xrayConfig: json['xrayConfig'] as String? ?? '',
      xrayShareLink: json['xrayShareLink'] as String? ?? '',
      endpointPortOverride: (json['endpointPortOverride'] as num?)?.toInt(),
      showXrayConfig: isLegacySwockProfile
          ? true
          : json['showXrayConfig'] as bool? ?? false,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      lastUsedAt: DateTime.tryParse(json['lastUsedAt'] as String? ?? '') ??
          DateTime.now(),
      favorite: json['favorite'] as bool? ?? false,
      notes: json['notes'] as String?,
      isSelected: json['isSelected'] as bool? ?? false,
      isLocked: json['isLocked'] as bool? ?? false,
      expiresAt: DateTime.tryParse(json['expiresAt'] as String? ?? ''),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'server': server,
        'port': port,
        'uuid': uuid,
        'alterId': alterId,
        'flow': flow,
        'security': security,
        'protocol': protocol.name,
        'core': core.name,
        'cipher': cipher,
        'password': password,
        'hysteriaObfs': hysteriaObfs,
        'hysteriaObfsPassword': hysteriaObfsPassword,
        'transport': transport.name,
        'webSocket': webSocket.toJson(),
        'tls': tls.toJson(),
        'proxy': proxy.toJson(),
        'ssh': ssh.toJson(),
        'dns': dns.toJson(),
        'metadata': metadata,
        'xrayConfig': xrayConfig,
        'xrayShareLink': xrayShareLink,
        if (endpointPortOverride != null)
          'endpointPortOverride': endpointPortOverride,
        'showXrayConfig': showXrayConfig,
        'createdAt': createdAt.toIso8601String(),
        'lastUsedAt': lastUsedAt.toIso8601String(),
        'favorite': favorite,
        'notes': notes,
        'isSelected': isSelected,
        'isLocked': isLocked,
        if (expiresAt != null) 'expiresAt': expiresAt!.toIso8601String(),
      };
}
