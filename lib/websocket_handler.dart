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

final Set<WebSocketChannel> _connectedChannels = {};

Handler createWebSocketHandler(
  MatchmakingService matchmakingService,
  DatabaseService databaseService,
  ChessValidator chessValidator,
  AuthService authService,
  RatingService ratingService,
) {
  final rateLimiter = RateLimiter(maxRequests: 10, window: Duration(seconds: 1));

  return webSocketHandler((WebSocketChannel channel) {
    _connectedChannels.add(channel);
    print('🔌 [WEBSOCKET] New connection established');

    String? userId;
    String? currentGameId;
    String? currentVariantKey;
    String? currentTimeControlType;

    channel.stream.listen((message) async {
      print('📨 [WEBSOCKET] Message received: $message');
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
              channel.sink.add(jsonEncode({'authenticated': true, 'user_id': userId}));
              print('✅ [AUTH] User authenticated: $userId');
            } else {
              channel.sink.add(jsonEncode({'error': 'Invalid token'}));
              print('❌ [AUTH] Invalid token');
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
          final timeControlType = data['time_control_type'] as String? ?? 'blitz';
          final timeControl = data['time_control'] as String? ?? '3:00|0';
          final rating = data['rating'] as int? ?? 1500;
          final ratingRange = data['rating_range'] as int? ?? 200;

          print('🔍 [MATCHMAKING] find_match called: userId=$userId, variant=$variant, timeControl=$timeControl, rating=$rating');

          final result = await matchmakingService.findMatch(
            userId!,
            variant,
            timeControlType,
            timeControl,
            rating,
            ratingRange,
            channel,
          );

          print('✅ [MATCHMAKING] Result: matchFound=${result.matchFound}, gameId=${result.gameId}');

          if (!result.matchFound) {
            channel.sink.add(jsonEncode(result.toJson()));
          } else {
            currentGameId = result.gameId;
            currentVariantKey = variant;
            currentTimeControlType = timeControlType;

            channel.sink.add(jsonEncode({
              'match_found': true,
              'game_id': result.gameId,
              'white_id': result.whiteId,
              'black_id': result.blackId,
              'your_color': result.whiteId == userId ? 'white' : 'black',
              'initial_fen': result.initialFen,
            }));
          }

        } else if (action == 'get_queue') {
          final queue = matchmakingService.getQueueDebug();
          channel.sink.add(jsonEncode({
            'queue': queue,
            'count': queue.length,
          }));

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

          if (gameId.length > 100 || !RegExp(r'^[\w-]+$').hasMatch(gameId)) {
            channel.sink.add(jsonEncode({'error': 'Invalid game_id format'}));
            return;
          }

          final game = matchmakingService.getGame(gameId);
          if (game == null) {
            channel.sink.add(jsonEncode({'error': 'Game not found'}));
            return;
          }

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

          // ✅ Проверка хода — только один раз (была задублирована)
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

          channel.sink.add(jsonEncode({
            'move_accepted': true,
            'move_number': newMoveNumber,
            'move': move,
            'new_fen': moveResult.newFen,
            'white_time': whiteTime,
            'black_time': blackTime,
          }));

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
          channel.sink.add(endMessage);
          opponentChannel?.sink.add(endMessage);

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

        } else {
          channel.sink.add(jsonEncode({'error': 'Unknown action: $action'}));
        }

      } catch (e, stackTrace) {
        print('❌ [WEBSOCKET] Handler error: $e');
        print(stackTrace);
        channel.sink.add(jsonEncode({'error': 'Invalid message format'}));
      }
    }, onDone: () {
      _connectedChannels.remove(channel); 
      print('🔌 [WEBSOCKET] Connection closed for userId=$userId');
      if (userId != null) {
        matchmakingService.removeFromQueue(userId!);
        matchmakingService.handlePlayerDisconnect(userId!);
      }
    }, onError: (error) {
      _connectedChannels.remove(channel);
      print('❌ [WEBSOCKET] Error for userId=$userId: $error');
      if (userId != null) {
        matchmakingService.removeFromQueue(userId!);
        matchmakingService.handlePlayerDisconnect(userId!);
      }
    });
  });
}

Set<WebSocketChannel> getConnectedChannels() => _connectedChannels;