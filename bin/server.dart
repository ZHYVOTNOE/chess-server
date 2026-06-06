import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:server/matchmaking_service.dart';
import 'package:server/websocket_handler.dart';
import 'package:server/database_service.dart';
import 'package:server/chess_validator.dart';

// Initialize services
final matchmakingService = MatchmakingService();
final databaseService = DatabaseService();
final chessValidator = ChessValidator();

// Configure routes.
final _router = Router()
  ..get('/', _rootHandler)
  ..get('/echo/<message>', _echoHandler)
  ..get('/ws', createWebSocketHandler(matchmakingService, databaseService, chessValidator));

Response _rootHandler(Request req) {
  return Response.ok('Hello, World!\n');
}

Response _echoHandler(Request request) {
  final message = request.params['message'];
  return Response.ok('$message\n');
}

void main(List<String> args) async {
  // Use any available host or container IP (usually `0.0.0.0`).
  final ip = InternetAddress.anyIPv4;

  // Configure a pipeline that logs requests.
  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addHandler(_router.call);

  // For running in containers, we respect the PORT environment variable.
  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  final server = await serve(handler, ip, port);
  print('Server listening on port ${server.port}');

  // Graceful Shutdown
  ProcessSignal.sigterm.watch().listen((signal) async {
    print('Received SIGTERM, shutting down gracefully...');
    databaseService.close();
    await server.close();
    exit(0);
  });
}