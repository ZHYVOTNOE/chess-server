import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

class AuthService {
  final String _jwtSecret;

  AuthService(this._jwtSecret);

  /// Верифицирует Supabase JWT токен и возвращает user_id
  /// Возвращает null если токен невалидный или просроченный
  String? verifyToken(String token) {
    try {
      final jwt = JWT.verify(
        token,
        SecretKey(_jwtSecret),
        issuer: 'https://supabase.co',
      );

      // Supabase использует поле 'sub' для user_id
      return jwt.subject;
    } on JWTException {
      return null;
    }
  }

  /// Проверяет валидность токена без извлечения user_id
  bool isValidToken(String token) {
    return verifyToken(token) != null;
  }
}
