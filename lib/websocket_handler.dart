import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'matchmaking_service.dart';
import 'database_service.dart';
import 'chess_validator.dart';
import 'auth_service.dart';
import 'rate_limiter.dart';
import 'rating_service.dart';

Handler createWebSocketHandler(
  MatchmakingService matchmakingService,
  DatabaseService databaseService,
  ChessValidator chessValidator,
  AuthService authService,
  RatingService ratingService,
) {
  final rateLimiter = RateLimiter(maxRequests: 10, window: Duration(seconds: 1));

  return webSocketHandler((WebSocketChannel channel) {
    String? userId;
    String? currentGameId;
    String? currentVariantKey;
    String? currentTimeControlType;

    channel.stream.listen((message) async {
      try {
        final data = jsonDecode(message as String);
        final action = data['action'];

        // Rate limiting check
        if (userId != null && !rateLimiter.allow(userId!)) {
          channel.sink.add(jsonEncode({'error': 'Rate limit exceeded'}));
          return;
        }

        if (action == 'authenticate') {
          final token = data['token'] as String?;
          if (token != null) {
            final verifiedUserId = authService.verifyToken(token);
            if (verifiedUserId != null) {
              userId = verifiedUserId;
              channel.sink.add(jsonEncode({'authenticated': true}));
            } else {
              channel.sink.add(jsonEncode({'error': 'Invalid token'}));
            }
          } else {
            channel.sink.add(jsonEncode({'error': 'Missing token'}));
          }
        } else if (action == 'reconnect') {
          final token = data['token'] as String?;
          if (token != null) {
            final verifiedUserId = authService.verifyToken(token);
            if (verifiedUserId != null) {
              userId = verifiedUserId;
            } else {
              channel.sink.add(jsonEncode({'error': 'Invalid token'}));
              return;
            }
          }
          final gameId = data['game_id'] as String?;

          if (userId == null || gameId == null) {
            channel.sink.add(jsonEncode({'error': 'Missing user_id or game_id'}));
            return;
          }

          // Validate gameId format and length
          if (gameId.length > 100 || !RegExp(r'^[\w-]+$').hasMatch(gameId)) {
            channel.sink.add(jsonEncode({'error': 'Invalid game_id format'}));
            return;
          }

          final game = matchmakingService.getGame(gameId);
          if (game == null) {
            channel.sink.add(jsonEncode({'error': 'Game not found or already finished'}));
            return;
          }

          if (userId != game.whiteId && userId != game.blackId) {
            channel.sink.add(jsonEncode({'error': 'You are not a participant'}));
            return;
          }

          matchmakingService.updatePlayerChannel(gameId, userId!, channel);

          final currentFen = matchmakingService.getGameState(gameId);
          channel.sink.add(jsonEncode({
            'reconnected': true,
            'game_id': gameId,
            'your_color': userId == game.whiteId ? 'white' : 'black',
            'current_fen': currentFen,
            'white_id': game.whiteId,
            'black_id': game.blackId,
          }));
        } else if (action == 'find_match') {
          final token = data['token'] as String?;
          if (token != null) {
            final verifiedUserId = authService.verifyToken(token);
            if (verifiedUserId != null) {
              userId = verifiedUserId;
            } else {
              channel.sink.add(jsonEncode({
                'error': 'Invalid token',
                'match_found': false,
              }));
              return;
            }
          }

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

          final result = await matchmakingService.findMatch(
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
            // Store game info for rating calculation
            currentGameId = result.gameId;
            currentVariantKey = variant;
            currentTimeControlType = timeControl;
            
            channel.sink.add(jsonEncode({
              'match_found': true,
              'game_id': result.gameId,
              'white_id': result.whiteId,
              'black_id': result.blackId,
              'your_color': result.whiteId == userId ? 'white' : 'black',
              'initial_fen': matchmakingService.getGame(result.gameId!)?.initialFen,
            }));
          }
        } else if (action == 'make_move') {
          if (userId == null) {
            channel.sink.add(jsonEncode({'error': 'User not authenticated'}));
            return;
          }

          final gameId = data['game_id'] as String?;
          final move = data['move'] as String?;
          final whiteTime = data['white_time'] as int?;
          final blackTime = data['black_time'] as int?;

          if (gameId == null || move == null || whiteTime == null || blackTime == null) {
            channel.sink.add(jsonEncode({'error': 'Missing required fields'}));
            return;
          }

          // Validate gameId format and length
          if (gameId.length > 100 || !RegExp(r'^[\w-]+$').hasMatch(gameId)) {
            channel.sink.add(jsonEncode({'error': 'Invalid game_id format'}));
            return;
          }

          final game = matchmakingService.getGame(gameId);
          if (game == null) {
            channel.sink.add(jsonEncode({'error': 'Game not found'}));
            return;
          }

          // Проверка статуса игры (#3)
          if (game.status != 'in_progress') {
            channel.sink.add(jsonEncode({
              'move_accepted': false,
              'error': 'Game is already finished',
            }));
            return;
          }

          if (userId != game.whiteId && userId != game.blackId) {
            channel.sink.add(jsonEncode({'error': 'You are not a participant in this game'}));
            return;
          }

          final currentFen = matchmakingService.getGameState(gameId);
          if (currentFen == null) {
            channel.sink.add(jsonEncode({'error': 'Game state not found'}));
            return;
          }

          final currentTurn = chessValidator.getCurrentTurn(currentFen);
          if (currentTurn == null) {
            channel.sink.add(jsonEncode({
              'move_accepted': false,
              'error': 'Invalid game state',
            }));
            return;
          }

          final isWhiteTurn = currentTurn == 'w';
          final isPlayerWhite = userId == game.whiteId;

          if (isWhiteTurn != isPlayerWhite) {
            channel.sink.add(jsonEncode({
              'move_accepted': false,
              'error': 'Not your turn',
            }));
            return;
          }

          if (isWhiteTurn != isPlayerWhite) {
            channel.sink.add(jsonEncode({
              'move_accepted': false,
              'error': 'Not your turn',
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

          final saved = await databaseService.addMove(
            gameId,
            moveResult.newFen!,
            newMoveNumber,
            whiteTime,
            blackTime,
          );

          if (!saved) {
            channel.sink.add(jsonEncode({
              'move_accepted': false,
              'error': 'Failed to save move',
            }));
            return;
          }

          matchmakingService.updateGameState(gameId, moveResult.newFen!);

          final moveConfirmation = jsonEncode({
            'move_accepted': true,
            'move_number': newMoveNumber,
            'move': move,
            'new_fen': moveResult.newFen,
            'white_time': whiteTime,
            'black_time': blackTime,
          });
          channel.sink.add(moveConfirmation);

          final opponentChannel = userId == game.whiteId ? game.blackChannel : game.whiteChannel;
          opponentChannel?.sink.add(jsonEncode({
            'opponent_move': true,
            'game_id': gameId,
            'move': move,
            'move_number': newMoveNumber,
            'new_fen': moveResult.newFen,
            'white_time': whiteTime,
            'black_time': blackTime,
          }));

          // Проверка окончания игры
          final gameEndResult = chessValidator.checkGameEnd(moveResult.newFen!, game.variant);
          if (gameEndResult.isGameOver) {
            final endMessage = jsonEncode({
              'game_over': true,
              'game_id': gameId,
              'result': gameEndResult.result,
              'reason': gameEndResult.reason,
              'new_fen': moveResult.newFen,
            });
            
            channel.sink.add(endMessage);
            opponentChannel?.sink.add(endMessage);
            
            // Update ratings using Glicko-2
            if (currentGameId != null) {
              try {
                await ratingService.updateRatings(
                  gameId: currentGameId!,
                  whiteId: game.whiteId,
                  blackId: game.blackId,
                  variantKey: currentVariantKey ?? 'standard',
                  timeControlType: currentTimeControlType ?? 'blitz',
                  result: gameEndResult.result ?? 'draw',
                );
              } catch (e) {
                print('Error updating ratings: $e');
              }
            }
            
            matchmakingService.removeGame(gameId);
          }
        } else if (action == 'get_moves') {
          if (userId == null) {
            channel.sink.add(jsonEncode({'error': 'User not authenticated'}));
            return;
          }

          final gameId = data['game_id'] as String?;
          final fromMoveNumber = data['from_move_number'] as int? ?? 0;

          if (gameId == null) {
            channel.sink.add(jsonEncode({'error': 'Missing game_id'}));
            return;
          }

          // Validate gameId format and length
          if (gameId.length > 100 || !RegExp(r'^[\w-]+$').hasMatch(gameId)) {
            channel.sink.add(jsonEncode({'error': 'Invalid game_id format'}));
            return;
          }

          final moves = await databaseService.getMoves(gameId, fromMoveNumber: fromMoveNumber);
          final movesJson = moves.map((m) => m.toJson()).toList();

          channel.sink.add(jsonEncode({'moves': movesJson}));
        } else if (action == 'cancel_match') {
          if (userId != null) {
            matchmakingService.removeFromQueue(userId!);
            channel.sink.add(jsonEncode({'match_cancelled': true}));
          }
        } else if (action == 'resign') {
          if (userId == null) {
            channel.sink.add(jsonEncode({'error': 'User not authenticated'}));
            return;
          }

          final gameId = data['game_id'] as String?;
          if (gameId == null) {
            channel.sink.add(jsonEncode({'error': 'Missing game_id'}));
            return;
          }

          // Validate gameId format and length
          if (gameId.length > 100 || !RegExp(r'^[\w-]+$').hasMatch(gameId)) {
            channel.sink.add(jsonEncode({'error': 'Invalid game_id format'}));
            return;
          }

          final game = matchmakingService.getGame(gameId);
          if (game == null) {
            channel.sink.add(jsonEncode({'error': 'Game not found'}));
            return;
          }

          if (userId != game.whiteId && userId != game.blackId) {
            channel.sink.add(jsonEncode({'error': 'You are not a participant in this game'}));
            return;
          }

          final winnerId = userId == game.whiteId ? game.blackId : game.whiteId;
          final result = userId == game.whiteId ? 'black' : 'white';

          final endMessage = jsonEncode({
            'game_over': true,
            'game_id': gameId,
            'result': 'resignation',
            'winner': winnerId,
          });

          final opponentChannel = userId == game.whiteId ? game.blackChannel : game.whiteChannel;
          channel.sink.add(endMessage); // Отправителю
          opponentChannel?.sink.add(endMessage); // Сопернику

          // Update ratings using Glicko-2
          if (currentGameId != null) {
            try {
              await ratingService.updateRatings(
                gameId: currentGameId!,
                whiteId: game.whiteId,
                blackId: game.blackId,
                variantKey: currentVariantKey ?? 'standard',
                timeControlType: currentTimeControlType ?? 'blitz',
                result: result,
              );
            } catch (e) {
              print('Error updating ratings: $e');
            }
          }

          matchmakingService.removeGame(gameId);
        }
      } catch (e) {
        print('Handler error: $e');
        channel.sink.add(jsonEncode({'error': 'Invalid message format'}));
      }
    }, onDone: () {
      if (userId != null) {
        matchmakingService.removeFromQueue(userId!);
        matchmakingService.handlePlayerDisconnect(userId!);
      }
    }, onError: (error) {
      print('WebSocket error: $error');
      if (userId != null) {
        matchmakingService.removeFromQueue(userId!);
        matchmakingService.handlePlayerDisconnect(userId!);
      }
    });
  });
}