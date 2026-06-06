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
    String? userId;

    channel.stream.listen((message) async {
      try {
        final data = jsonDecode(message as String);
        final action = data['action'];

        if (action == 'find_match') {
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
          } else {
            // НОВОЕ: уведомляем инициатора поиска о найденном матче
            channel.sink.add(jsonEncode({
              'match_found': true,
              'game_id': result.gameId,
              'white_id': result.whiteId,
              'black_id': result.blackId,
              'your_color': result.whiteId == userId ? 'white' : 'black',
            }));
          }
        } else if (action == 'make_move') {
          if (userId == null) {
            channel.sink.add(jsonEncode({
              'error': 'User not authenticated',
            }));
            return;
          }

          final gameId = data['game_id'] as String?;
          final move = data['move'] as String?;
          final whiteTime = data['white_time'] as int?;
          final blackTime = data['black_time'] as int?;

          if (gameId == null || move == null || whiteTime == null || blackTime == null) {
            channel.sink.add(jsonEncode({
              'error': 'Missing required fields',
            }));
            return;
          }

          final game = matchmakingService.getGame(gameId);
          if (game == null) {
            channel.sink.add(jsonEncode({
              'error': 'Game not found',
            }));
            return;
          }

          final currentFen = matchmakingService.getGameState(gameId);
          if (currentFen == null) {
            channel.sink.add(jsonEncode({
              'error': 'Game state not found',
            }));
            return;
          }

          final moveResult = chessValidator.applyMove(currentFen, move, game.variant);

          if (!moveResult.success) {
            channel.sink.add(jsonEncode({
              'move_accepted': false,
              'error': moveResult.error ?? 'Invalid move',
            }));
            return;
          }

          final lastMoveNumber = await databaseService.getLastMoveNumber(gameId);
          final newMoveNumber = lastMoveNumber + 1;

          await databaseService.addMove(
            gameId,
            moveResult.newFen!,
            newMoveNumber,
            whiteTime,
            blackTime,
          );

          matchmakingService.updateGameState(gameId, moveResult.newFen!);

          channel.sink.add(jsonEncode({
            'move_accepted': true,
            'move_number': newMoveNumber,
            'move': move,
            'new_fen': moveResult.newFen,
            'white_time': whiteTime,
            'black_time': blackTime,
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