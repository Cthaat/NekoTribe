import 'package:flutter/foundation.dart';
import 'package:passkeys/authenticator.dart';
import 'package:passkeys/types.dart';

class PasskeyClient {
  PasskeyClient({required String Function() readApiBaseUrl})
    : _readApiBaseUrl = readApiBaseUrl;

  final String Function() _readApiBaseUrl;
  final _authenticator = PasskeyAuthenticator();

  bool get isSupported =>
      kIsWeb ||
      const {
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
        TargetPlatform.windows,
      }.contains(defaultTargetPlatform);

  Future<Map<String, dynamic>> create(Map<String, dynamic> options) async {
    final request = RegisterRequestType.fromJson(options);
    _checkWindowsDomain(request.relyingParty.id);
    final credential = await _authenticator.register(request);
    return credential.toJson();
  }

  Future<Map<String, dynamic>> authenticate(
    Map<String, dynamic> options,
  ) async {
    final request = AuthenticateRequestType.fromJson(options);
    _checkWindowsDomain(request.relyingPartyId);
    final credential = await _authenticator.authenticate(request);
    return credential.toJson();
  }

  void _checkWindowsDomain(String rpId) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return;
    // Windows Hello uses the supplied RP ID to construct the credential origin.
    final endpoint = Uri.tryParse(_readApiBaseUrl());
    final host = endpoint?.host.toLowerCase();
    final domain = rpId.toLowerCase();
    if (endpoint?.scheme != 'https' ||
        host == null ||
        domain.isEmpty ||
        (host != domain &&
            !(domain.contains('.') && host.endsWith('.$domain')))) {
      throw DomainNotAssociatedException(null);
    }
  }
}
