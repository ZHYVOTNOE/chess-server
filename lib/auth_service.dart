import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

class AuthService {
  final String jwtSecret;

  AuthService(this.jwtSecret);

  String? verifyToken(String token) {
    try {
      final jwt = JWT.verify(
        token,
        SecretKey(jwtSecret),
      );

      return jwt.subject;
    } catch (_) {
      return null;
    }
  }
}