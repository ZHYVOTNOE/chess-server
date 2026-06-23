import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:synchronized/synchronized.dart';
import 'chess_validator.dart';

class MatchmakingQueueEntry {
  final String userId;
  final String variantKey;
  final String timeControlType;
  final String timeControl;
  final int rating;
  final int ratingRange;
  final DateTime enteredAt;
  WebSocketChannel? channel;

  MatchmakingQueueEntry({
    required this.userId,
    required this.variantKey,
    required this.timeControlType,
    required this.timeControl,
    required this.rating,
    required this.ratingRange,
    required this.enteredAt,
    this.channel,
  });
}

class GameSession {
  final String gameId;
  final String whiteId;
  final String blackId;
  final String variant;
  final String timeControlType;
  final String timeControl;
  String status;
  final DateTime createdAt;
  final String? initialFen;
  WebSocketChannel? whiteChannel;
  WebSocketChannel? blackChannel;

  GameSession({
    required this.gameId,
    required this.whiteId,
    required this.blackId,
    required this.variant,
    required this.timeControlType,
    required this.timeControl,
    required this.status,
    required this.createdAt,
    this.initialFen,
    this.whiteChannel,
    this.blackChannel,
  });

  Map<String, dynamic> toJson() {
    return {
      'game_id': gameId,
      'white_id': whiteId,
      'black_id': blackId,
      'variant': variant,
      'time_control': timeControl,
      'status': status,
      'created_at': createdAt.toIso8601String(),
      if (initialFen != null) 'initial_fen': initialFen,
    };
  }
}

class MatchmakingService {
  final List<MatchmakingQueueEntry> _queue = [];
  final Map<String, GameSession> _games = {};
  final Map<String, String> _gameStates = {};
  final Map<String, Timer> _disconnectTimers = {};
  final Random _random = Random();
  final ChessValidator _chessValidator;
  final Lock _lock = Lock();
  
  static const int reconnectTimeoutSeconds = 30;

  MatchmakingService({ChessValidator? chessValidator})
      : _chessValidator = chessValidator ?? ChessValidator();

    Future<MatchmakingResult> findMatch(
      String userId,
      String variantKey,
      String timeControlType,
      String timeControl,
      int rating,
      int ratingRange,
      WebSocketChannel? channel,
    ) async {
      GameSession? createdGame;
      MatchmakingQueueEntry? opponent;

      final initialFen = _chessValidator.getInitialFen(variantKey);

      stdout.writeln('');
      stdout.writeln('========================================');
      stdout.writeln('🔍 FIND MATCH REQUEST');
      stdout.writeln('userId=$userId');
      stdout.writeln('variant=$variantKey');
      stdout.writeln('timeControlType=$timeControlType');
      stdout.writeln('timeControl=$timeControl');
      stdout.writeln('rating=$rating');
      stdout.writeln('ratingRange=$ratingRange');
      stdout.writeln('queueSizeBefore=${_queue.length}');
      stdout.writeln('========================================');

      await _lock.synchronized(() {
        stdout.writeln('📋 CURRENT QUEUE:');

        if (_queue.isEmpty) {
          stdout.writeln('   <empty>');
        } else {
          for (final q in _queue) {
            stdout.writeln(
              '   user=${q.userId} '
              'variant=${q.variantKey} '
              'type=${q.timeControlType} '
              'tc=${q.timeControl} '
              'rating=${q.rating} '
              'range=${q.ratingRange}',
            );
          }
        }

        // удаляем старую запись игрока
        final beforeRemove = _queue.length;
        _queue.removeWhere((e) => e.userId == userId);

        if (_queue.length != beforeRemove) {
          stdout.writeln(
            '🗑 Removed previous queue entry for user $userId',
          );
        }

        int opponentIndex = -1;

        for (int i = 0; i < _queue.length; i++) {
          final entry = _queue[i];

          stdout.writeln(
            '🔎 Checking opponent ${entry.userId}',
          );

          if (entry.variantKey != variantKey) {
            stdout.writeln(
              '❌ Variant mismatch: ${entry.variantKey} != $variantKey',
            );
            continue;
          }

          if (entry.timeControl != timeControl) {
            stdout.writeln(
              '❌ TimeControl mismatch: ${entry.timeControl} != $timeControl',
            );
            continue;
          }

          if (entry.userId == userId) {
            stdout.writeln(
              '❌ Same user',
            );
            continue;
          }

          final ratingDiff = (entry.rating - rating).abs();
          final minRange = min(ratingRange, entry.ratingRange);

          stdout.writeln(
            '📊 ratingDiff=$ratingDiff minRange=$minRange',
          );

          if (ratingDiff <= minRange) {
            opponent = entry;
            opponentIndex = i;

            stdout.writeln(
              '✅ MATCH FOUND WITH ${entry.userId}',
            );

            break;
          } else {
            stdout.writeln(
              '❌ Rating mismatch',
            );
          }
        }

        if (opponent != null) {
          _queue.removeAt(opponentIndex);

          stdout.writeln(
            '🎮 Creating game: $userId vs ${opponent!.userId}',
          );

          createdGame = createGame(
            userId,
            opponent!.userId,
            variantKey,
            timeControlType,
            timeControl,
            initialFen,
            channel,
            opponent!.channel,
          );

          stdout.writeln(
            '🎮 Game created: ${createdGame!.gameId}',
          );
        } else {
          _queue.add(
            MatchmakingQueueEntry(
              userId: userId,
              variantKey: variantKey,
              timeControlType: timeControlType,
              timeControl: timeControl,
              rating: rating,
              ratingRange: ratingRange,
              enteredAt: DateTime.now(),
              channel: channel,
            ),
          );

          stdout.writeln(
            '📥 Added to queue: $userId',
          );

          stdout.writeln(
            '📋 Queue size now: ${_queue.length}',
          );
        }
      });

      if (createdGame != null && opponent != null) {
        stdout.writeln(
          '📨 Sending notification to opponent ${opponent!.userId}',
        );

        try {
          if (opponent!.channel != null) {
            _sendMatchFoundNotification(
              opponent!.channel!,
              createdGame!,
              opponent!.userId == createdGame!.whiteId,
            );
          }

          stdout.writeln(
            '✅ Opponent notified successfully',
          );
        } catch (e) {
          stdout.writeln(
            '❌ Failed to notify opponent: $e',
          );
        }

        return MatchmakingResult(
          matchFound: true,
          gameId: createdGame!.gameId,
          whiteId: createdGame!.whiteId,
          blackId: createdGame!.blackId,
          initialFen: initialFen,
        );
      }

      stdout.writeln(
        '⌛ No match found, waiting in queue',
      );

      return MatchmakingResult(
        matchFound: false,
      );
    }

  GameSession createGame(
    String player1Id,
    String player2Id,
    String variant,
    String timeControlType,
    String timeControl,
    String initialFen,
    WebSocketChannel? player1Channel,
    WebSocketChannel? player2Channel,
  ) {
    final isPlayer1White = _random.nextBool();
    final gameId = _generateGameId();
    
    final game = GameSession(
      gameId: gameId,
      whiteId: isPlayer1White ? player1Id : player2Id,
      blackId: isPlayer1White ? player2Id : player1Id,
      variant: variant,
      timeControlType: timeControlType,
      timeControl: timeControl,
      status: 'in_progress',
      createdAt: DateTime.now(),
      initialFen: initialFen,
      whiteChannel: isPlayer1White ? player1Channel : player2Channel,
      blackChannel: isPlayer1White ? player2Channel : player1Channel,
    );

    _games[gameId] = game;
    _gameStates[gameId] = initialFen;
    return game;
  }

  String? getGameState(String gameId) {
    return _gameStates[gameId];
  }

  void updateGameState(String gameId, String fen) {
    _gameStates[gameId] = fen;
  }

  void removeGame(String gameId) {
    _games.remove(gameId);
    _gameStates.remove(gameId);
    _disconnectTimers[gameId]?.cancel();
    _disconnectTimers.remove(gameId);
  }

  List<GameSession> getUserGames(String userId) {
    return _games.values.where((game) => 
      game.whiteId == userId || game.blackId == userId
    ).toList();
  }

  List<Map<String, dynamic>> getQueueDebug() {
    return _queue.map((entry) => {
      'userId': entry.userId,
      'variantKey': entry.variantKey,
      'timeControlType': entry.timeControlType,
      'timeControl': entry.timeControl,
      'rating': entry.rating,
      'ratingRange': entry.ratingRange,
      'enteredAt': entry.enteredAt.toIso8601String(),
    }).toList();
  }

  void updatePlayerChannel(String gameId, String userId, WebSocketChannel channel) {
    final game = _games[gameId];
    if (game == null) return;
    
    if (game.whiteId == userId) {
      game.whiteChannel = channel;
    } else if (game.blackId == userId) {
      game.blackChannel = channel;
    }
    
    _disconnectTimers[gameId]?.cancel();
    _disconnectTimers.remove(gameId);
  }

  void handlePlayerDisconnect(String userId) {
    final userGames = getUserGames(userId);
    
    for (final game in userGames) {
      if (_disconnectTimers.containsKey(game.gameId)) continue;
      
      final opponentId = game.whiteId == userId ? game.blackId : game.whiteId;
      final opponentChannel = game.whiteId == userId ? game.blackChannel : game.whiteChannel;
      
      opponentChannel?.sink.add(jsonEncode({
        'opponent_disconnected': true,
        'game_id': game.gameId,
        'reconnect_timeout': reconnectTimeoutSeconds,
      }));
      
      _disconnectTimers[game.gameId] = Timer(
        Duration(seconds: reconnectTimeoutSeconds),
        () {
          if (_games.containsKey(game.gameId)) {
            opponentChannel?.sink.add(jsonEncode({
              'game_over': true,
              'game_id': game.gameId,
              'result': 'disconnect',
              'winner': opponentId,
            }));
            removeGame(game.gameId);
          }
        },
      );
    }
  }

  void removeFromQueue(String userId) {
    _queue.removeWhere((e) => e.userId == userId);
  }

  GameSession? getGame(String gameId) {
    return _games[gameId];
  }

  List<MatchmakingQueueEntry> getQueue() {
    return List.from(_queue);
  }

  List<GameSession> getGames() {
    return _games.values.toList();
  }

  String _generateGameId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = _random.nextInt(10000);
    return '$timestamp-$random';
  }

  void _sendMatchFoundNotification(
    WebSocketChannel channel,
    GameSession game,
    bool isWhite,
  ) {
    final response = {
      'match_found': true,
      'game_id': game.gameId,
      'white_id': game.whiteId,
      'black_id': game.blackId,
      'your_color': isWhite ? 'white' : 'black',
      'initial_fen': game.initialFen,
    };
    channel.sink.add(jsonEncode(response));
  }

  void dispose() {
    for (final timer in _disconnectTimers.values) {
      timer.cancel();
    }
    _disconnectTimers.clear();
    
    for (final game in _games.values) {
      game.whiteChannel?.sink.close();
      game.blackChannel?.sink.close();
    }
  }
}

class MatchmakingResult {
  final bool matchFound;
  final String? gameId;
  final String? whiteId;
  final String? blackId;
  final String? initialFen; // ✅ ДОБАВЛЕНО

  MatchmakingResult({
    required this.matchFound,
    this.gameId,
    this.whiteId,
    this.blackId,
    this.initialFen,
  });

  Map<String, dynamic> toJson() {
    if (matchFound) {
      return {
        'match_found': true,
        'game_id': gameId,
        'white_id': whiteId,
        'black_id': blackId,
        'initial_fen': initialFen, // ✅ ДОБАВЛЕНО
      };
    } else {
      return {'match_found': false};
    }
  }
}