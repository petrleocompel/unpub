import 'dart:io';
import 'dart:typed_data';

/// Why [url] cannot be a webhook URL, or null if it can.
///
/// Only http(s) URLs with a host, without credentials or a fragment, and
/// plain http only when [allowHttp] is true.
String? webhookUrlProblem(Uri? url, {required bool allowHttp}) {
  if (url == null) return 'the URL is invalid';
  if (url.scheme != 'https' && url.scheme != 'http') {
    return 'the URL must start with https://';
  }
  if (url.scheme == 'http' && !allowHttp) {
    return 'the URL must use https (webhooks.allowHttp is false)';
  }
  if (url.host.isEmpty) return 'the URL needs a host';
  if (url.userInfo.isNotEmpty) {
    return 'the URL must not contain credentials';
  }
  if (url.hasFragment) return 'the URL must not have a fragment';
  if (url.toString().length > 2048) return 'the URL is too long';
  return null;
}

/// Whether [address] is somewhere a webhook must not reach unless
/// `webhooks.allowPrivateNetworks` is true: loopback, unspecified,
/// link-local, private (RFC 1918), shared (RFC 6598), unique local,
/// site-local, multicast, broadcast or reserved, also as an IPv4-mapped IPv6
/// address.
bool isPrivateAddress(InternetAddress address) {
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) return _privateIPv4(bytes);
  if (address.type != InternetAddressType.IPv6 || bytes.length != 16) {
    return true;
  }
  // ::ffff:a.b.c.d and the deprecated ::a.b.c.d.
  final mapped = bytes.sublist(0, 10).every((byte) => byte == 0) &&
      ((bytes[10] == 0xff && bytes[11] == 0xff) ||
          (bytes[10] == 0 && bytes[11] == 0));
  if (mapped) {
    final v4 = bytes.sublist(12);
    // :: and ::1 are covered by the IPv4 checks of 0.0.0.0 and 0.0.0.1.
    return _privateIPv4(v4);
  }
  // NAT64 64:ff9b::/96 embeds an IPv4 address too.
  if (bytes[0] == 0x00 &&
      bytes[1] == 0x64 &&
      bytes[2] == 0xff &&
      bytes[3] == 0x9b &&
      bytes.sublist(4, 12).every((byte) => byte == 0)) {
    return _privateIPv4(bytes.sublist(12));
  }
  final first = bytes[0];
  final second = bytes[1];
  if ((first & 0xfe) == 0xfc) return true; // fc00::/7 unique local
  if (first == 0xfe && (second & 0xc0) == 0x80) return true; // fe80::/10
  if (first == 0xfe && (second & 0xc0) == 0xc0) return true; // fec0::/10
  if (first == 0xff) return true; // multicast
  return false;
}

bool _privateIPv4(Uint8List bytes) {
  final [a, b, ...] = bytes;
  return a == 0 || // this network
      a == 10 ||
      a == 127 ||
      (a == 100 && (b & 0xc0) == 64) || // 100.64.0.0/10
      (a == 169 && b == 254) ||
      (a == 172 && (b & 0xf0) == 16) ||
      (a == 192 && b == 168) ||
      (a == 192 && b == 0 && bytes[2] == 0) || // 192.0.0.0/24
      (a == 198 && (b & 0xfe) == 18) || // 198.18.0.0/15 benchmarking
      a >= 224; // multicast, reserved and broadcast
}

/// A webhook target that must not be contacted.
class RefusedAddressException implements Exception {
  final String message;

  const RefusedAddressException(this.message);

  @override
  String toString() => message;
}

/// The address to connect to for [host], resolved now.
///
/// Unless [allowPrivate] is true, every address the name resolves to has to
/// be public, so that a name with one public and one private address cannot
/// be used to reach the private one. The connection then goes to the address
/// checked here, never to a second lookup.
Future<InternetAddress> resolveWebhookHost(String host,
    {required bool allowPrivate,
    Future<List<InternetAddress>> Function(String host)? lookup}) async {
  final literal = InternetAddress.tryParse(host);
  final addresses = literal != null
      ? [literal]
      : await (lookup ?? InternetAddress.lookup)(host);
  if (addresses.isEmpty) {
    throw RefusedAddressException('$host does not resolve');
  }
  if (!allowPrivate) {
    for (final address in addresses) {
      if (isPrivateAddress(address)) {
        throw RefusedAddressException(
            '$host resolves to the private address ${address.address}, which '
            'webhooks may not reach (webhooks.allowPrivateNetworks is false)');
      }
    }
  }
  return addresses.first;
}
