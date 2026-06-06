import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'matchmaking_service.dart';
import 'database_service.dart';
import 'chess_validator.dart';

Handler createWebSocketHandler(
  MatchmakingService matchmakingService,
  DatabaseService databaseService,
  ChessValidator chessValidator,
) {
  return webSocketHandler((WebSocketChannel channel) {
    // Извлекаем user_id из заголовков при подключении
    // В реальном приложении это может быть JWT токен или сессия
    String? userId;

    channel.stream.listen((message) async {
      try {
        final data = jsonDecode(message as String);
        final action = data['action'];

        if (action == 'find_match') {
          // Проверяем авторизацию
          userId ??= data['user_id'] as String?;

          if (userId == null) {
            channel.sink.add(jsonEncode({
              'error': 'User not authenticated',
              'match_found': false,
            }));
            return;
          }

          final variant = data['variant'] as String? ?? 'standard';
          final timeControl = data['time_control'] as String? ?? 'blitz';
          final rating = data['rating'] as int? ?? 1200;
          final ratingRange = data['rating_range'] as int? ?? 200;

          final result = matchmakingService.findMatch(
            userId!,
            variant,
            timeControl,
            rating,
            ratingRange,
            channel,
          );

          if (!result.matchFound) {
            channel.sink.add(jsonEncode(result.toJson()));
          }
          // Если матч найден, уведомление уже отправлено в matchmakingService
        } else if (action == 'make_move') {
          if (userId == null) {
            channel.sink.add(jsonEncode({
              'error': 'User not authenticated',
            }));
            return;
          }

          final gameId = data['game_id'] as String?;
          final fen = data['fen'] as String?;
          final whiteTime = data['white_time'] as int?;
          final blackTime = data['black_time'] as int?;

          if (gameId == null || fen == null || whiteTime == null || blackTime == null) {
            channel.sink.add(jsonEncode({
              'error': 'Missing required fields',
            }));
            return;
          }

          // Получаем игру для валидации варианта
          final game = matchmakingService.getGame(gameId);
          if (game == null) {
            channel.sink.add(jsonEncode({
              'error': 'Game not found',
            }));
            return;
          }

          // Валидируем FEN
          if (!chessValidator.validateMove(fen, game.variant)) {
            channel.sink.add(jsonEncode({
              'move_accepted': false,
              'error': 'Invalid FEN',
            }));
            return;
          }

          // Получаем последний номер хода
          final lastMoveNumber = await databaseService.getLastMoveNumber(gameId);
          final newMoveNumber = lastMoveNumber + 1;

          // Добавляем ход в базу данных
          await databaseService.addMove(
            gameId,
            fen,
            newMoveNumber,
            whiteTime,
            blackTime,
          );

          channel.sink.add(jsonEncode({
            'move_accepted': true,
            'move_number': newMoveNumber,
          }));
        } else if (action == 'get_moves') {
          if (userId == null) {
            channel.sink.add(jsonEncode({
              'error': 'User not authenticated',
            }));
            return;
          }

          final gameId = data['game_id'] as String?;
          final fromMoveNumber = data['from_move_number'] as int? ?? 0;

          if (gameId == null) {
            channel.sink.add(jsonEncode({
              'error': 'Missing game_id',
            }));
            return;
          }

          final moves = await databaseService.getMoves(gameId, fromMoveNumber: fromMoveNumber);
          final movesJson = moves.map((m) => m.toJson()).toList();

          channel.sink.add(jsonEncode({
            'moves': movesJson,
          }));
        } else if (action == 'cancel_match') {
          if (userId != null) {
            matchmakingService.removeFromQueue(userId!);
            channel.sink.add(jsonEncode({'match_cancelled': true}));
          }
        } else if (action == 'authenticate') {
          userId = data['user_id'] as String?;
          if (userId != null) {
            channel.sink.add(jsonEncode({'authenticated': true}));
          } else {
            channel.sink.add(jsonEncode({'error': 'Invalid user_id'}));
          }
        }
      } catch (e) {
        channel.sink.add(jsonEncode({'error': 'Invalid message format'}));
      }
    }, onDone: () {
      // При отключении удаляем пользователя из очереди
      if (userId != null) {
        matchmakingService.removeFromQueue(userId!);
      }
    }, onError: (error) {
      print('WebSocket error: $error');
      if (userId != null) {
        matchmakingService.removeFromQueue(userId!);
      }
    });
  });
}
