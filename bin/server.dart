import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:server/matchmaking_service.dart';
import 'package:server/websocket_handler.dart';
import 'package:server/database_service.dart';
import 'package:server/chess_validator.dart';
import 'package:server/auth_service.dart';
import 'package:server/supabase_service.dart';
import 'package:server/rating_service.dart';
import 'package:dotenv/dotenv.dart';

// Load environment variables
late final String _supabaseUrl;
late final String _supabaseAnonKey;

void _loadEnv() {
  final env = DotEnv(includePlatformEnvironment: true)..load();
  _supabaseUrl = env['SUPABASE_URL'] ?? '';
  _supabaseAnonKey = env['SUPABASE_ANON_KEY'] ?? '';
}

// Initialize services
late final MatchmakingService matchmakingService;
late final DatabaseService databaseService;
late final ChessValidator chessValidator;
late final AuthService authService;
late final SupabaseService supabaseService;
late final RatingService ratingService;

void _initializeServices() {
  _loadEnv();

  matchmakingService = MatchmakingService();
  chessValidator = ChessValidator();
  authService = AuthService(_supabaseUrl); 
  supabaseService = SupabaseService(
    supabaseUrl: _supabaseUrl,
    supabaseAnonKey: _supabaseAnonKey,
  );
  databaseService = DatabaseService(supabaseService);
  ratingService = RatingService(supabaseService);
}

Response _rootHandler(Request req) {
  return Response.ok('Hello, World!\n');
}

Response _echoHandler(Request request) {
  final message = request.params['message'];
  return Response.ok('$message\n');
}

void main(List<String> args) async {
    stdout.lineTerminator = '\n';
  stdout.writeln('🚀 SERVER STARTING - NEW CODE VERSION');
  _initializeServices();

  // ✅ WebSocket handler создаётся ПОСЛЕ инициализации сервисов
  final wsHandler = createWebSocketHandler(
    matchmakingService,
    databaseService,
    chessValidator,
    authService,
    ratingService,
  );

  // ✅ Роутер только для HTTP-эндпоинтов
  final router = Router()
    ..get('/', _rootHandler)
    ..get('/echo/<message>', _echoHandler);

  // ✅ WebSocket перехватывается ДО роутера
  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addHandler((Request request) {
        if (request.url.path == 'ws') {
          print('🔌 [MAIN] WebSocket upgrade request received for /ws');
          return wsHandler(request);
        }
        return router.call(request);
      });

  final ip = InternetAddress.anyIPv4;
  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  final server = await serve(handler, ip, port);
  print('Server listening on port ${server.port}');
  print('WebSocket endpoint: ws://localhost:${server.port}/ws');

  Timer.periodic(Duration(seconds: 30), (_) {
    final channels = getConnectedChannels();
    for (var channel in channels) {
      try {
        // Отправляем легковесное JSON-сообщение
        channel.sink.add(jsonEncode({
          'action': 'ping', 
          'timestamp': DateTime.now().millisecondsSinceEpoch
        }));
      } catch (e) {
        // Если отправка упала, значит соединение точно мертво. 
        // Оно удалится из списка в onDone/onError.
        print('⚠️ [KEEP-ALIVE] Failed to send ping: $e');
      }
    }
  });

  // Graceful Shutdown
  void shutdown() async {
    print('Shutting down gracefully...');

    for (final game in matchmakingService.getGames()) {
      final shutdownMsg = jsonEncode({
        'server_restarting': true,
        'game_id': game.gameId,
      });
      game.whiteChannel?.sink.add(shutdownMsg);
      game.blackChannel?.sink.add(shutdownMsg);
    }

    await Future.delayed(Duration(seconds: 1));

    databaseService.close();
    matchmakingService.dispose();
    await server.close();
    exit(0);
  }

  ProcessSignal.sigterm.watch().listen((_) => shutdown());
  ProcessSignal.sigint.watch().listen((_) => shutdown());
}