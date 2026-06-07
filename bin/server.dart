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
late final String _jwtSecret;

void _loadEnv() {
  final env = DotEnv(includePlatformEnvironment: true)..load();
  _supabaseUrl = env['SUPABASE_URL'] ?? '';
  _supabaseAnonKey = env['SUPABASE_ANON_KEY'] ?? '';
  _jwtSecret = env['JWT_SECRET'] ?? 'default-secret-change-in-production';
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
  authService = AuthService(_jwtSecret);
  supabaseService = SupabaseService(
    supabaseUrl: _supabaseUrl,
    supabaseAnonKey: _supabaseAnonKey,
  );
  databaseService = DatabaseService(supabaseService);
  ratingService = RatingService(supabaseService);
}

// Configure routes.
final _router = Router()
  ..get('/', _rootHandler)
  ..get('/echo/<message>', _echoHandler)
  ..get('/ws', createWebSocketHandler(matchmakingService, databaseService, chessValidator, authService, ratingService));

Response _rootHandler(Request req) {
  return Response.ok('Hello, World!\n');
}

Response _echoHandler(Request request) {
  final message = request.params['message'];
  return Response.ok('$message\n');
}

void main(List<String> args) async {
  _initializeServices();
  
  final ip = InternetAddress.anyIPv4;

  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addHandler(_router.call);

  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  final server = await serve(handler, ip, port);
  print('Server listening on port ${server.port}');

  // Graceful Shutdown
  ProcessSignal.sigterm.watch().listen((signal) async {
    print('Received SIGTERM, shutting down gracefully...');
    
    // Notify all players in active games
    for (final game in matchmakingService.getGames()) {
      final shutdownMsg = jsonEncode({
        'server_restarting': true,
        'game_id': game.gameId,
      });
      game.whiteChannel?.sink.add(shutdownMsg);
      game.blackChannel?.sink.add(shutdownMsg);
    }
    
    // Give time for messages to be sent
    await Future.delayed(Duration(seconds: 1));
    
    databaseService.close();
    matchmakingService.dispose();
    await server.close();
    exit(0);
  });

  ProcessSignal.sigint.watch().listen((signal) async {
    print('Received SIGINT, shutting down gracefully...');
    
    // Notify all players in active games
    for (final game in matchmakingService.getGames()) {
      final shutdownMsg = jsonEncode({
        'server_restarting': true,
        'game_id': game.gameId,
      });
      game.whiteChannel?.sink.add(shutdownMsg);
      game.blackChannel?.sink.add(shutdownMsg);
    }
    
    // Give time for messages to be sent
    await Future.delayed(Duration(seconds: 1));
    
    databaseService.close();
    matchmakingService.dispose();
    await server.close();
    exit(0);
  });
}